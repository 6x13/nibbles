;;;; tests.lisp -- tests for various bits of functionality

(cl:defpackage :nibbles-tests
  (:use :cl))

(cl:in-package :nibbles-tests)

;;; Basic tests for correctness.

(defun make-byte-combiner (n-bytes big-endian-p)
  (let ((count 0)
        (buffer 0))
    #'(lambda (byte)
        (setf buffer
              (if big-endian-p
                  (logior (ash buffer 8) byte)
                  (let ((x (logior (ash byte (* 8 count)) buffer)))
                    (if (= count n-bytes)
                        (ash x -8)
                        x))))
        (unless (= count n-bytes)
          (incf count))
        (cond
          ((= count n-bytes)
           (let ((val (ldb (byte (* 8 n-bytes) 0) buffer)))
             (multiple-value-prog1 (values val t)
               (setf buffer val))))
          (t (values 0 nil))))))

(defun generate-random-test (ref-size signedp big-endian-p
                             &optional (n-octets 4096))
  (do* ((byte-kind (if signedp 'signed-byte 'unsigned-byte))
        (n-bits (* 8 ref-size))
        (total-octets (+ n-octets (1- ref-size)))
        (bv (make-array total-octets
                        :element-type '(unsigned-byte 8)))
        (ev (make-array n-octets
                        :element-type `(,byte-kind ,n-bits)))
        (i 0 (1+ i))
        (j 0)
        (combiner (make-byte-combiner ref-size big-endian-p)))
      ((>= i total-octets) (values bv ev n-octets))
    (let ((byte (random 256)))
      (multiple-value-bind (aggregate set-p) (funcall combiner byte)
        (setf (aref bv i) byte)
        (when set-p
          (setf (aref ev j)
                (if (and signedp (logbitp (1- n-bits) aggregate))
                    (dpb aggregate (byte n-bits 0) -1)
                    aggregate))
          (incf j))))))

(defun compile-quietly (form)
  (handler-bind ((style-warning #'muffle-warning)
                 #+sbcl (sb-ext:compiler-note #'muffle-warning))
    (compile nil form)))

(defun ref-test (reffer ref-size signedp big-endian-p
                 &optional (n-octets 4096))
  (multiple-value-bind (byte-vector expected-vector)
      (generate-random-test ref-size signedp big-endian-p n-octets)
    (flet ((run-test (reffer)
             (loop for i from 0 below n-octets
                   for j from 0
                   do (let ((reffed-val (funcall reffer byte-vector i))
                            (expected-val (aref expected-vector j)))
                        (unless (= reffed-val expected-val)
                          (error "wanted ~D, got ~D from ~A"
                                 expected-val reffed-val
                                 (subseq byte-vector i (+ i ref-size)))))
                   finally (return :ok))))
      (run-test reffer)
      (when (typep byte-vector '(simple-array (unsigned-byte 8) (*)))
        (let ((compiled (compile-quietly
                           `(lambda (v i)
                              (declare (type (simple-array (unsigned-byte 8) (*)) v))
                              (declare (type (integer 0 #.(1- array-dimension-limit))))
                              (declare (optimize speed (debug 0)))
                              (,reffer v i)))))
          (run-test compiled))))))

(defun set-test (reffer set-size signedp big-endian-p
                 &optional (n-octets 4096))
  ;; We use GET-SETF-EXPANSION to avoid reaching too deeply into
  ;; internals.  This bit relies on knowing that the writer-form will be
  ;; a simple function call whose CAR is the internal setter, but I
  ;; think that's a bit better than :: references everywhere.
  (multiple-value-bind (vars vals store-vars writer-form reader-form)
      (get-setf-expansion `(,reffer x i))
    (declare (ignore vars vals store-vars reader-form))
    (let ((setter (car writer-form)))
      ;; Sanity check.
      (unless (eq (symbol-package setter) (find-package :nibbles))
        (error "need to update setter tests!"))
      (multiple-value-bind (byte-vector expected-vector)
          (generate-random-test set-size signedp big-endian-p n-octets)
        (flet ((run-test (setter)
                 (loop with fill-vec = (let ((v (copy-seq byte-vector)))
                                         (fill v 0)
                                         v)
                       for i from 0 below n-octets
                       for j from 0
                       do (funcall setter fill-vec i (aref expected-vector j))
                       finally (return
                                 (if (mismatch fill-vec byte-vector)
                                     (error "wanted ~A, got ~A" byte-vector fill-vec)
                                     :ok)))))
          (run-test setter)
          (when (typep byte-vector '(simple-array (unsigned-byte 8) (*)))
            (let ((compiled (compile-quietly
                             `(lambda (v i new)
                                (declare (type (simple-array (unsigned-byte 8) (*)) v))
                                (declare (type (integer 0 #.(1- array-dimension-limit))))
                                (declare (type (,(if signedp 'signed-byte 'unsigned-byte)
                                                 ,(* set-size 8)) new))
                                (declare (optimize speed (debug 0)))
                                (,setter v i new)))))
              (run-test compiled))))))))

;;; Big-endian integer ref tests

(rtest:deftest :ub16ref/be
  (ref-test 'nibbles:ub16ref/be 2 nil t)
  :ok)

(rtest:deftest :sb16ref/be
  (ref-test 'nibbles:sb16ref/be 2 t t)
  :ok)

(rtest:deftest :ub32ref/be
  (ref-test 'nibbles:ub32ref/be 4 nil t)
  :ok)

(rtest:deftest :sb32ref/be
  (ref-test 'nibbles:sb32ref/be 4 t t)
  :ok)

(rtest:deftest :ub64ref/be
  (ref-test 'nibbles:ub64ref/be 8 nil t)
  :ok)

(rtest:deftest :sb64ref/be
  (ref-test 'nibbles:sb64ref/be 8 t t)
  :ok)

;;; Big-endian set tests
;;;
;;; FIXME: DEFSETF doesn't automagically define SETF functions, so we
;;; have to reach into internals to do these tests.  It would be ideal
;;; if we didn't have to do this.

(rtest:deftest :ub16set/be
  (set-test 'nibbles:ub16ref/be 2 nil t)
  :ok)

(rtest:deftest :sb16set/be
  (set-test 'nibbles:sb16ref/be 2 t t)
  :ok)

(rtest:deftest :ub32set/be
  (set-test 'nibbles:ub32ref/be 4 nil t)
  :ok)

(rtest:deftest :sb32set/be
  (set-test 'nibbles:sb32ref/be 4 t t)
  :ok)

(rtest:deftest :ub64set/be
  (set-test 'nibbles:ub64ref/be 8 nil t)
  :ok)

(rtest:deftest :sb64set/be
  (set-test 'nibbles:sb64ref/be 8 t t)
  :ok)

;;; Little-endian integer ref tests

(rtest:deftest :ub16ref/le
  (ref-test 'nibbles:ub16ref/le 2 nil nil)
  :ok)

(rtest:deftest :sb16ref/le
  (ref-test 'nibbles:sb16ref/le 2 t nil)
  :ok)

(rtest:deftest :ub32ref/le
  (ref-test 'nibbles:ub32ref/le 4 nil nil)
  :ok)

(rtest:deftest :sb32ref/le
  (ref-test 'nibbles:sb32ref/le 4 t nil)
  :ok)

(rtest:deftest :ub64ref/le
  (ref-test 'nibbles:ub64ref/le 8 nil nil)
  :ok)

(rtest:deftest :sb64ref/le
  (ref-test 'nibbles:sb64ref/le 8 t nil)
  :ok)

;;; Little-endian set tests

(rtest:deftest :ub16set/le
  (set-test 'nibbles:ub16ref/le 2 nil nil)
  :ok)

(rtest:deftest :sb16set/le
  (set-test 'nibbles:sb16ref/le 2 t nil)
  :ok)

(rtest:deftest :ub32set/le
  (set-test 'nibbles:ub32ref/le 4 nil nil)
  :ok)

(rtest:deftest :sb32set/le
  (set-test 'nibbles:sb32ref/le 4 t nil)
  :ok)

(rtest:deftest :ub64set/le
  (set-test 'nibbles:ub64ref/le 8 nil nil)
  :ok)

(rtest:deftest :sb64set/le
  (set-test 'nibbles:sb64ref/le 8 t nil)
  :ok)
