;;; Extend ASDF and the CFFI groveller to be MPI aware
(defpackage :cl-mpi-asdf-utilities
  (:use :asdf :cl :uiop)
  (:export #:mpi-stub #:grovel-mpi-file))

(in-package :cl-mpi-asdf-utilities)

(defclass grovel-mpi-file (cffi-grovel:grovel-file) ())

(defclass mpi-stub (c-source-file)
  ((%mpi-info :initform ""
              :accessor mpi-info)))

;;; use "mpicc" as compiler for all mpi related cffi-grovel files
(defmethod perform ((op cffi-grovel::process-op)
                    (c grovel-mpi-file))
  (let ((cc (getenv "CC"))
        (cffi-grovel::*cc* "mpicc"))
    (unless (or (not cc)
                (string-equal cc "mpicc"))
      (warn
       (format nil
        "The environment variable CC with value ~A overrides the recommended
        compiler mpicc. Some headers and libraries might not get found." cc)))
    (call-next-method)))

(defun compute-mpi-info ()
  "Produce some value that is EQUALP unless the MPI implementation changes."
  (multiple-value-bind (output stderr exit-code)
      (uiop:run-program "mpicc -show~%" :output :string
                                        :ignore-error-status t)
    (declare (ignore stderr))
    (if (zerop exit-code)
        output
        nil)))

(defmethod output-files ((o compile-op) (c mpi-stub))
  (declare (ignorable o))
  (list (make-pathname :defaults (component-pathname c)
                       :type "so")))

;; Convert a single c source file into a shared library that can be loaded
;; with ASDF:LOAD-OP.
(defmethod perform ((o compile-op) (c mpi-stub))
  (let ((target (output-file o c))
        (source (component-pathname c)))
    (let ((possible-commands
            (list
             (format nil "mpicc -shared -fPIC -o ~A ~A" target source)
             ;; more commands can be added here if there is a system where the
             ;; above command fails
             )))
      (block compile-stub-library
        (dolist (cmd possible-commands)
          (if (multiple-value-bind (stdout stderr exit-code)
                  (uiop:run-program cmd :ignore-error-status t
                                        :error-output :string)
                (declare (ignore stdout stderr))
                (zerop exit-code))
              (progn
                (format *standard-output* "; ~A~%" cmd)
                (return-from compile-stub-library))))
        (error "Failed to compile c-mpi-stub.c - please check mpicc."))
      (setf (mpi-info c) (compute-mpi-info)))))

(defmethod perform ((o load-op) (c mpi-stub))
  (cffi:load-foreign-library (output-file 'compile-op c)))

(defmethod operation-done-p ((o compile-op) (c mpi-stub))
  "Return NIL if the current MPI implementation differs from the one that
was used to build this component."
  (if (equalp (mpi-info c)
              (compute-mpi-info))
      (call-next-method)
      nil))
