#lang typed/racket/base

(require typed/safe/ops
         racket/list
         racket/match
         racket/vector
         racket/performance-hint
         "../unsafe.rkt"
         "array-struct.rkt"
         "array-transform.rkt"
         "array-constructors.rkt"
         "array-broadcast.rkt"
         "for-each.rkt"
         "utils.rkt")

(provide (all-defined-out))

;; ===================================================================================================
;; Array ref/set!

(begin-encourage-inline

  (: unsafe-array-ref (All (A) ((Array A) Indexes -> A)))
  (define (unsafe-array-ref arr js)
    ((unsafe-array-proc arr) js))

  (: unsafe-array-set! (All (A) ((Settable-Array A) Indexes A -> Void)))
  (define (unsafe-array-set! arr js v)
    ((unsafe-settable-array-set-proc arr) js v))
  
  (: array-ref (All (A) ((Array A) In-Indexes -> A)))
  (define (array-ref arr js)
    ((unsafe-array-proc arr) (check-array-indexes 'array-ref (array-shape arr) js)))

  (: array-set! (All (A) ((Settable-Array A) In-Indexes A -> Void)))
  (define (array-set! arr js v)
    (define ds (array-shape arr))
    (define set-proc (unsafe-settable-array-set-proc arr))
    (set-proc (check-array-indexes 'array-set! ds js) v))
  
  )  ; begin-encourage-inline

;; ===================================================================================================
;; Indexing using array of indexes

(: array-indexes-ref (All (A) ((Array A) (Array In-Indexes) -> (Array A))))
(define (array-indexes-ref arr idxs)
  (define ds (array-shape idxs))
  (define idxs-proc (unsafe-array-proc idxs))
  (array-default-strict
   (unsafe-build-array ds (λ: ([js : Indexes]) (array-ref arr (idxs-proc js))))))

(: array-indexes-set! (All (A) ((Settable-Array A) (Array In-Indexes) (Array A) -> Void)))
(define (array-indexes-set! arr idxs vals)
  (define ds (array-shape-broadcast (list (array-shape idxs) (array-shape vals))))
  (let ([idxs  (array-broadcast idxs ds)]
        [vals  (array-broadcast vals ds)])
    (define idxs-proc (unsafe-array-proc idxs))
    (define vals-proc (unsafe-array-proc vals))
    (for-each-array-index ds (λ (js) (array-set! arr (idxs-proc js) (vals-proc js))))))

;; ===================================================================================================
;; Slicing

(struct: Slice ([start : (U Fixnum #f)]
                [end : (U Fixnum #f)]
                [step : Fixnum])
  #:property prop:custom-write
  (λ (s port _)
    (write-string (format "(:: ~a ~a ~a)" (slice-start s) (slice-end s) (slice-step s)) port)))

(struct: Slice-Dots () #:property prop:custom-write (λ (s port _) (write-string "::..." port)))

(struct: Slice-New-Axis ([length : Index])
  #:property prop:custom-write
  (λ (s port _) (write-string (format "(::new ~a)" (slice-new-axis-length s)) port)))

(define-type -Slice Slice)
(define-type -Slice-Dots Slice-Dots)
(define-type -Slice-New-Axis Slice-New-Axis)
(define-type Slice-Spec-- (U Integer Slice (Sequenceof Integer)))
(define-type Slice-Spec- (U Slice-Spec-- Slice-New-Axis))
(define-type Slice-Spec (U Slice-Spec- Slice-Dots))

(define slice? Slice?)
(define slice-start Slice-start)
(define slice-end Slice-end)
(define slice-step Slice-step)

(define ::... (Slice-Dots))

(define slice-dots? Slice-Dots?)

(: ::new (case-> (-> Slice-New-Axis)
                 (Integer -> Slice-New-Axis)))
(define (::new [dk 1])
  (cond [(index? dk)  (Slice-New-Axis dk)]
        [else  (raise-argument-error '::new "Index" dk)]))

(define slice-new-axis? Slice-New-Axis?)
(define slice-new-axis-length Slice-New-Axis-length)

(: :: (case-> (-> Slice)
              ((U Integer #f) -> Slice)
              ((U Integer #f) (U Integer #f) -> Slice)
              ((U Integer #f) (U Integer #f) Integer -> Slice)))
(define ::
  (case-lambda
    [()  (Slice 0 #f 1)]
    [(end)  (cond [(and end (fixnum? end))  (Slice 0 end 1)]
                  [end  (raise-argument-error 'Slice "Fixnum or #f" end)]
                  [else  (Slice 0 #f 1)])]
    [(start end)  (:: start end 1)]
    [(start end step)
     (cond
       [(fixnum? step)
        (cond
          [(and start (fixnum? start))
           (cond
             [(and end (fixnum? end))  (Slice start end step)]
             [end  (raise-argument-error 'Slice "Fixnum or #f" 1 start end step)]
             [else  (Slice start #f step)])]
          [start  (raise-argument-error 'Slice "Fixnum or #f" 0 start end step)]
          [else
           (cond [(and end (fixnum? end))  (Slice #f end step)]
                 [end  (raise-argument-error 'Slice "Fixnum or #f" 1 start end)]
                 [else  (Slice #f #f step)])])]
       [else
        (raise-argument-error 'Slice "Fixnum" 2 start end step)])]))

(: slice->range-values (Slice Index -> (Values Fixnum Fixnum Fixnum)))
(define (slice->range-values s dk)
  (define start (Slice-start s))
  (define end (Slice-end s))
  (define step (Slice-step s))
  (if (zero? dk)
      (cond [(< step 0)  (values (or start -1) (or end -1) step)]
            [else        (values (or start 0) (or end 0) step)])
      (cond [(< step 0)  (values (or start (- dk 1)) (or end -1) step)]
            [else        (values (or start 0) (or end dk) step)])))

(: slice->sequence (Slice Index -> (Sequenceof Integer)))
(define (slice->sequence s dk)
  (define-values (start end step) (slice->range-values s dk))
  (in-range start end step))

(require racket/sequence)

(: slice->list (Slice Index -> (Listof Integer)))
(define (slice->list s dk)
  (sequence->list (slice->sequence s dk)))

(: slice->vector (Slice Integer Index -> (Vectorof Index)))
(define (slice->vector s k dk)
  (define-values (start end step) (slice->range-values s dk))
  (define size
    (cond [(step . < . 0)  (quotient (+ (- end start) (+ step 1)) step)]
          [else  (quotient (+ (- end start) (- step 1)) step)]))
  (cond [(size . <= . 0)  (vector)]
        [(index? size)         
         ; <refined-local> Refinement added to jks for vector-set! operation.
         (define jks : (Refine [jks : (Vectorof Index)] (= size (len jks))) (make-vector size 0))
         (let loop ([#{i : Nonnegative-Fixnum} 0] [#{jk : Fixnum} start])
           (cond [(i . >= . size)  jks]
                 [(or (jk . < . 0) (jk . >= . dk))
                  (error 'slice->vector
                         "expected Index < ~e in slice ~e (axis ~e); given ~e"
                         dk s k jk)]
                 [else
                  (safe-vector-set! jks i jk)
                  (loop (+ i 1) (unsafe-fx+ jk step))]))]
        [else
         (error 'array-slice-ref "axis for slice ~e (axis ~e) is too large" s k)]))

(: slices->array-axis-transform
   (All (A) (Symbol (Array A) (Listof Slice-Spec--)
                    -> (Values (Array A) (Vectorof (Vectorof Index))))))
(define (slices->array-axis-transform name arr slices)
  (define n (length slices))
  (define ds (array-shape arr))
  (define dims (vector-length ds))
  (define-values (new-arr old-jss)
    (let loop : (Values (Array A) (Listof (Vectorof Index)))
      ([slices : (Listof Slice-Spec--) (reverse slices)]
       [k : (Refine [i : Integer] (<= -1 i (+ dims -1))) (- dims 1)]
       [arr : (Array A)  arr]
       [jss : (Listof (Vectorof Index))  null])
      (cond
        [(or (k . < . 0)
             (null? slices))
         (values arr jss)]
        [else
         (define dk (safe-vector-ref ds k))
         (match-define (cons s rst-slices) slices)
         (cond [(integer? s)
                (when (or (s . < . 0) (s . >= . dk))
                  (error name "expected Index < ~e in slice ~e (axis ~e)" dk s k))
                (loop rst-slices (unsafe-fx- k 1) (array-axis-ref arr k s) jss)]
               [(slice? s)
                (loop rst-slices
                      (unsafe-fx- k 1)
                      arr
                      (cons (slice->vector s k dk) jss))]
               [else
                (define js
                  (for/fold: ([js : (Listof Index)  null]) ([jk s])
                    (cond [(or (jk . < . 0) (jk . >= . dk))
                           (error name "expected Index < ~e in slice ~e (axis ~e); given ~e"
                                  dk s k jk)]
                          [else  (cons jk js)])))
                (loop rst-slices
                      (unsafe-fx- k 1)
                      arr
                      (cons ((inst list->vector Index) (reverse js)) jss))])])))
  (values new-arr (list->vector old-jss)))

(: expand-dots (Index (Listof Slice-Spec) -> (Listof Slice-Spec-)))
(define (expand-dots dims slices)
  (define n (count (λ (s) (and (not (slice-dots? s)) (not (slice-new-axis? s)))) slices))
  (let loop ([slices slices] [n n])
    (cond [(null? slices)  null]
          [(slice-dots? (car slices))
           (append (make-list (max 0 (- dims n)) (Slice #f #f 1))
                   (loop (cdr slices) dims))]
          [else  (cons (car slices) (loop (cdr slices) n))])))

(: extract-new-axes ((Listof Slice-Spec-) -> (Values (Listof Slice-Spec--)
                                                     (Listof (Pair Integer Index)))))
(define (extract-new-axes slices)
  (define-values (new-slices new-axes _)
    (for/fold: ([new-slices : (Listof Slice-Spec--)  null]
                [new-axes : (Listof (Pair Integer Index))  null]
                [k : Integer  0]
                ) ([s  (in-list slices)])
      (cond [(slice-new-axis? s)
             (values new-slices (cons (cons k (slice-new-axis-length s)) new-axes) k)]
            [else
             (values (cons s new-slices) new-axes (+ k 1))])))
  (values (reverse new-slices) (reverse new-axes)))

(: array-slice-ref (All (A) ((Array A) (Listof Slice-Spec) -> (Array A))))
(define (array-slice-ref arr orig-slices)
  (define dims (array-dims arr))
  (let*-values ([(slices)  (expand-dots dims orig-slices)]
                [(slices new-axes)  (extract-new-axes slices)])
    ;; number of indexes should match
    (define num-specs (length slices))
    (unless (= dims num-specs)
      (error 'array-slice-ref "expected list with ~e slice specifications; given ~e in ~e"
             dims num-specs orig-slices))
    (array-default-strict
     (parameterize ([array-strictness #f])
       (let-values ([(arr jss)  (slices->array-axis-transform 'array-slice-ref arr slices)])
         (for/fold: : (Array A) ([arr : (Array A)  (unsafe-array-axis-transform arr jss)]
                                 ) ([na  (in-list new-axes)])
           (match-define (cons k dk) na)
           (array-axis-insert arr k dk)))))))

(: array-slice-set! (All (A) ((Settable-Array A) (Listof Slice-Spec) (Array A) -> Void)))
(define (array-slice-set! arr slices vals)
  ;; No reason to make `idxs' strict, since we build it ourselves and don't return it
  (let ([idxs  (parameterize ([array-strictness #f])
                 (array-slice-ref (indexes-array (array-shape arr)) slices))])
    (array-indexes-set! arr idxs vals)))

;; ---------------------------------------------------------------------------------------------------

(: unsafe-array-axis-transform (All (A) ((Array A) (Vectorof (Vectorof Index)) -> (Array A))))
(define (unsafe-array-axis-transform arr old-jss)
  (define: new-ds : (Refine [v : Indexes] (= (len v) (len old-jss)))
    (vector-map vector-length old-jss))
  (define dims (vector-length new-ds))
  (cond 
    [(= 0 dims)
     arr]
    [(= 1 dims)
     (define g (unsafe-array-proc arr))
     ; <changed>
     (safe-build-array
      new-ds
      (λ: ([js : (Refine [v : Indexes] (= (len v) (len new-ds)))])
        (define j0 (safe-vector-ref js 0))
        (safe-vector-set! js 0 (unsafe-vector-ref (safe-vector-ref old-jss 0) j0))
        (define v (g js))
        (safe-vector-set! js 0 j0)
        v))]
    [(= 2 dims)
     (define g (unsafe-array-proc arr))
     ; <changed>
     (safe-build-array
      new-ds
      (λ: ([js : (Refine [v : Indexes] (= (len v) (len new-ds)))])
        (define j0 (safe-vector-ref js 0))
        (define j1 (safe-vector-ref js 1))
        (safe-vector-set! js 0 (unsafe-vector-ref (safe-vector-ref old-jss 0) j0))
        (safe-vector-set! js 1 (unsafe-vector-ref (safe-vector-ref old-jss 1) j1))
        (define v (g js))
        (safe-vector-set! js 0 j0)
        (safe-vector-set! js 1 j1)
        v))]
    [else
     (define old-js (make-thread-local-indexes dims))
     (unsafe-array-transform
      arr new-ds
      (λ: ([new-js : Indexes])
        (let ([old-js (old-js)])
          (let: loop : Indexes ([i : Nonnegative-Fixnum  0])
            (cond [(i . < . dims)
                   ; <nope> Vector-ref of new-js requires change to input type of unsafe-array-transform
                   (define new-ji (unsafe-vector-ref new-js i))
                   ; <nope> Vector ref of old-jss requires us to know that new-ds and old-jss have the same length.
                   ; I believe this is the case, but we cannot annotate new-ds to say this without changing the type
                   ; of vector-map.
                   (define old-ji (unsafe-vector-ref (unsafe-vector-ref old-jss i) new-ji))
                   (safe-vector-set! old-js i old-ji)
                   (loop (+ i 1))]
                  [else  old-js])))))]))

