(in-package :cl-mpi-test-suite)

(in-suite mpi-serial-tests)

(defmacro with-fresh-mpi-context (&body body)
  "Execute body with *STANDARD-COMMUNICATOR* bound to a new unique
communicator. This prevents errors within BODY to affect other parts of the
program."
  `(let ((*standard-communicator* (mpi-comm-dup)))
    (unwind-protect
         (progn ,@body)
      (mpi-comm-free *standard-communicator*))))

(test (mpi-wtime)
  (is (<= 0 (mpi-wtime)))
  (is (<= 0 (mpi-wtick))))

(test (mpi-init)
  "MPI Initialization."
  (mpi-init)
  (is (mpi-initialized))
  (is (not (mpi-finalized))))

(test (processor-name :depends-on mpi-init)
  "The function mpi-get-processor-name should return a string describing the
  current processor in use."
  (let ((processor-name (mpi-get-processor-name)))
    (is (stringp processor-name))
    (is (plusp (length processor-name)))))

(test (serial-groups :depends-on mpi-init)
  "MPI group management functions."
  (let* ((size (mpi-comm-size))
         (all-procs (mpi-comm-group +mpi-comm-world+))
         (first (mpi-group-incl all-procs 0))
         (all-but-first (mpi-group-excl all-procs 0))
         (evens (mpi-group-incl all-procs `(0 ,(- size 1) 2)))
         (odds  (if (> size 1)
                    (mpi-group-excl all-procs `(1 ,(- size 1) 2))
                    (mpi-group-incl all-procs))))
    (is (= size (mpi-group-size all-procs)))
    (is (= 1 (mpi-group-size first)))
    (is (= (- size 1) (mpi-group-size all-but-first)))
    (is (= (ceiling size 2) (mpi-group-size evens)))
    (is (= (floor size 2) (mpi-group-size odds)))
    (mpi-group-free all-procs first all-but-first odds evens)))

(test (mpi-buffering :depends-on mpi-init)
  (mpi::mpi-buffer-detach)
  (is (length mpi::*current-buffer*) 0)
  (mpi-demand-buffering 1000)
  (is (length mpi::*current-buffer*) 1000))

(test (mpi-context :depends-on mpi-init)
  (is (mpi-comm-free (mpi-comm-dup)))
  (let ((c1 *standard-communicator*)
        (c2 (mpi-comm-dup *standard-communicator*))
        (c3 (let ((group (mpi-comm-group *standard-communicator*)))
              (unwind-protect (mpi-comm-create group :comm *standard-communicator*)
                (mpi-group-free group)))))
    (unwind-protect
         (is (= (mpi-comm-size c1)
                (mpi-comm-size c2)
                (mpi-comm-size c3)))
      (mpi-comm-free c2)
      (mpi-comm-free c3))))

(test (mpi-split :depends-on mpi-context)
  "Test that mpi-comm-split is working."
  (with-fresh-mpi-context
    (let ((c1 (mpi-comm-split 0 0))
          (c2 (mpi-comm-split 0 (mpi-comm-rank)))
          (c3 (mpi-comm-split 0 (- (mpi-comm-rank))))
          (c4 (mpi-comm-split (mpi-comm-rank) -1))
          (c5 (mpi-comm-split +mpi-undefined+ 0)))
      (unwind-protect
           (progn
             (is (= (mpi-comm-size c1) (mpi-comm-size)))
             (is (= (mpi-comm-rank c1) (mpi-comm-rank)))
             (is (= (mpi-comm-size c2) (mpi-comm-size)))
             (is (= (mpi-comm-rank c2) (mpi-comm-rank)))
             (is (= (mpi-comm-size c3) (mpi-comm-size)))
             (is (= (mpi-comm-rank c3) (- (mpi-comm-size)
                                          (mpi-comm-rank)
                                          1)))
             (is (= (mpi-comm-size c4) 1))
             (is (= (mpi-comm-rank c4) 0))
             (is (mpi-null c5))))
      (mpi-comm-free c1)
      (mpi-comm-free c2)
      (mpi-comm-free c3)
      (mpi-comm-free c4))))

;;; point to point communication

(test (serial-mpi-sendrecv :depends-on mpi-context)
  (with-fresh-mpi-context
    (let ((self (mpi-comm-rank)))
      ;; send an array containing 10 zeros
      (with-static-vectors ((src 10 :element-type 'double-float
                                    :initial-element 0.0d0)
                            (dst 10 :element-type 'double-float
                                    :initial-element 1.0d0))
        (mpi-sendrecv src self dst self :send-tag 42 :recv-tag 42)
        (is (every #'zerop dst)))
      ;; swap the latter 10 elements of two buffers
      (with-static-vectors ((ones 20 :element-type 'double-float
                                     :initial-element 1.0d0)
                            (temp 10 :element-type 'double-float
                                     :initial-element 0.0d0)
                            (twos 20 :element-type 'double-float
                                     :initial-element 2.0d0))
        (mpi-sendrecv ones self temp self :send-start 10 :send-end 20)
        (mpi-sendrecv twos self ones self :send-start 10 :send-end 20
                                    :recv-start 10 :recv-end 20)
        (mpi-sendrecv temp self twos self :recv-start 10 :recv-end 20)
        (is (and (every (lambda (x) (= x 1.0d0)) (subseq ones 0 10))
                 (every (lambda (x) (= x 2.0d0)) (subseq ones 10 20))))
        (is (and (every (lambda (x) (= x 2.0d0)) (subseq twos 0 10))
                 (every (lambda (x) (= x 1.0d0)) (subseq twos 10 20))))))))

(test (serial-mpi-isend :depends-on mpi-context)
  (with-fresh-mpi-context
    (mpi-demand-buffering 1000)
    (let ((self (mpi-comm-rank)))
      (loop
        for (mode size)
          in '((:basic 1)
               (:basic 100)
               (:basic 1000000)
               (:buffered 10)
               (:synchronous 100)
               (:ready 1)
               (:ready 1000000))
        do
           (with-static-vectors ((src size :element-type 'double-float
                                           :initial-element 0.0d0)
                                 (dst size :element-type 'double-float
                                           :initial-element 1.0d0))
             (mpi-waitall
              (mpi-irecv dst self)
              (mpi-isend src self :mode mode))
             (is (every #'zerop dst)
                 (format nil "Error during ~s MPI-ISEND of ~d bytes."
                         mode (* 8 size))))))))

(test (mpi-probe :depends-on mpi-context)
  (with-fresh-mpi-context
    (let ((self (mpi-comm-rank)))
      (with-static-vectors ((src 3 :element-type 'double-float)
                            (dst 3 :element-type 'double-float))
        (let ((request (mpi-isend src self :tag 10)))
          (multiple-value-bind (size id tag)
              (mpi-probe self :tag 10)
            (is (= (* 3 8) size))
            (is (= id self))
            (is (= tag 10)))
          (is (every
               (lambda (x) (mpi-null x))
               (mpi-waitall
                request
                (mpi-irecv dst self :tag 10)))))))))

(test (mpi-iprobe :depends-on mpi-context)
  (with-fresh-mpi-context
    (let ((self (mpi-comm-rank)))
      (with-static-vectors ((src 3 :element-type 'double-float)
                            (dst 3 :element-type 'double-float))
        (let ((request (mpi-isend src self :tag 11)))
          (loop ; luckily MPI makes a progress guarantee for this case
            (multiple-value-bind (size id tag)
                (mpi-iprobe self :tag 11)
              (when size
                (is (= (* 3 8) size))
                (is (= id self))
                (is (= tag 11))
                (return))))
          (is (every
               (lambda (x) (mpi-null x))
               (mpi-waitall
                request
                (mpi-irecv dst self :tag 11)))))))))

(test (mpi-wait-and-test :depends-on mpi-context)
  (with-fresh-mpi-context
    (let ((self (mpi-comm-rank)))
      (with-static-vectors ((src 3 :element-type 'double-float)
                            (dst 3 :element-type 'double-float))
        (let ((recv-request (mpi-irecv src self :tag 12)))
          (multiple-value-bind (done request)
              (mpi-test recv-request)
            (is (not done))
            (is (typep recv-request 'mpi-request))
            (is (not (mpi-null request))))
          (let ((send-request (mpi-isend dst self :tag 12)))
            (loop until (and (mpi-test send-request)
                             (mpi-test recv-request)))
            (is (mpi-null (mpi-wait send-request)))
            (is (mpi-null (mpi-wait recv-request)))))))))
