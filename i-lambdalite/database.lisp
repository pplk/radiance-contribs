#|
 This file is a part of Radiance
 (c) 2015 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:i-lambdalite)

(defvar *schemas* (make-hash-table :test 'eql))

(defun ensure-collection (thing)
  (typecase thing
    (keyword thing)
    (T (intern (string-upcase thing) "KEYWORD"))))

(defun ensure-keyword (thing)
  (typecase thing
    (keyword
     (if (char= #\/ (char (symbol-name thing) 0))
         thing
         (intern (format NIL "/~:@(~a~)" thing) "KEYWORD")))
    (T (intern (format NIL "/~:@(~a~)" thing) "KEYWORD"))))

(defmacro with-table-change ((collection rows) &body body)
  ;; Oh boy we get to reimplement this ourselves because otherwise
  ;; we can't do the sorting and limiting.
  (let ((name (gensym "NAME")))
    `(let ((,name (ensure-collection ,collection)))
       (lambdalite::with-lock
         (when lambdalite::*tx*
           (let ((tmp-name (cdr (assoc ,name lambdalite::*tx-modified-list*)))) 
             (unless tmp-name
               (setf tmp-name (lambdalite::clone-temporary ,name))
               (push (cons ,name tmp-name) lambdalite::*tx-modified-list*)
               (setf ,name tmp-name))
             (setf ,name tmp-name)))
         (let ((,rows (gethash ,name lambdalite::*db*)))
           (setf (gethash ,name lambdalite::*db*)
                 (progn
                   ,@body))
           (unless lambdalite::*tx* (lambdalite::persist ,name)))))))

(define-trigger startup-done ()
  (db:connect (config-tree :lambdalite :default)))

(define-trigger server-stop ()
  (db:disconnect))

(defun database:connect (database-name)
  (with-simple-restart (skip "Skip connecting.")
    (flet ((err (msg) (error 'database-connection-failed :database database-name :message msg)))
      (let ((conn (config-tree :lambdalite :connections database-name)))
        (unless conn (err "No such connection found."))
        (when lambdalite::*db*
          (warn 'database-connection-already-open :database database-name)
          (db:disconnect))
        ;; Spec restarts for already open.
        (l:info :database "Connecting ~a ~a" database-name conn)
        (lambdalite:load-db
         :path (etypecase conn
                 (pathname conn)
                 (string (uiop:parse-native-namestring conn))))
        (trigger 'db:connected)))))

(defun database:disconnect ()
  (l:info :database "Disconnecting ~a" lambdalite::*db-path*)
  (setf lambdalite::*db* NIL
        lambdalite::*db-path* NIL)
  (trigger 'db:disconnected))

(defun database:connected-p ()
  (not (null lambdalite::*db*)))

(defun database:collections ()
  (lambdalite:list-tables))

(defun database:collection-exists-p (collection)
  (find (ensure-collection collection) (database:collections)))

(defun database:create (collection structure &key indices (if-exists :ignore))
  (setf (gethash (ensure-collection collection) *schemas*)
        structure))

(defun database:structure (collection)
  (gethash (ensure-collection collection) *schemas*))

(defun database:empty (collection)
  (lambdalite:del (ensure-collection collection) (constantly T)))

(defun database:drop (collection)
  (lambdalite::with-lock
    (remhash (ensure-collection collection) lambdalite::*db*)))

(defun sort-by-specs (list specs)
  (let ((sortfunc))
    (flet ((sorter (a b dir)
             (unless sortfunc
               (setf sortfunc
                     (etypecase a
                       (integer
                        (case dir
                          (:ASC #'<)
                          (:DESC #'>)))
                       (string
                        (case dir
                          (:ASC #'string<)
                          (:DESC #'string>))))))
             (funcall sortfunc a b)))
      (dolist (spec specs)
        (let ((field (ensure-keyword (first spec)))
              (order (second spec)))
          (setf list (sort list (lambda (a b)
                                  (sorter (getf a field)
                                          (getf b field)
                                          order))))))
      list)))

(defun database:iterate (collection query function &key fields (skip 0) amount sort accumulate)
  (funcall
   (if accumulate
       (lambda (fun seq)
         (mapcar fun seq))
       (lambda (fun seq)
         (map NIL fun seq)))
   (lambda (row)
     (funcall function
              (let ((table (make-hash-table :test 'equalp)))
                (if fields
                    (dolist (field fields)
                      (setf (gethash (subseq (string field) 1) table)
                            (getf row (ensure-keyword field))))
                    (loop for (field val) on row by #'cddr
                          do (setf (gethash (subseq (string field) 1) table) val)))
                table)))
   (subseq (sort-by-specs (lambdalite:select (ensure-collection collection) query) sort)
           skip (when amount (+ amount skip)))))

(defun database:select (collection query &key fields (skip 0) amount sort)
  (database:iterate collection query #'identity :fields fields :skip skip :amount amount :accumulate T))

(defun database:count (collection query)
  (length (database:select collection query :fields '(:_id))))

(defun database:insert (collection data)
  (let ((list (list :/_id (uuid:make-v4-uuid))))
    (etypecase data
      (hash-table
       (maphash (lambda (key val) (setf (getf list (ensure-keyword key)) val)) data))
      (list
       (loop for (key . val) in data do (setf (getf list (ensure-keyword key)) val))))
    (lambdalite:insert (ensure-collection collection) list)))

(defun database:remove (collection query &key (skip 0) amount sort)
  (with-table-change (collection rows)
    (let ((i 0))
      (delete-if (lambda (row)
                   (prog1 (and (<= skip i)
                               (< i (+ skip amount))
                               (funcall query row))
                     (incf i)))
                 (sort-by-specs rows sort)))))

(defun database:update (collection query data &key (skip 0) amount sort)
  (let ((setter (etypecase data
                  (hash-table
                   (lambda (row)
                     (maphash (lambda (key val)
                                (setf (getf row (ensure-keyword key)) val))
                              data)))
                  (list
                   (lambda (row)
                     (loop for (key . val) in data
                           do (setf (getf row (ensure-keyword key)) val)))))))
    (with-table-change (collection rows)
      (prog1 (setf rows (sort-by-specs rows sort))
        (loop for row in rows
              for i from 0
              while (or (not amount)
                        (< i (+ skip amount)))
              when (and (<= skip i)
                        (funcall query row))
              do (funcall setter row))))
    NIL))

(defmacro database:with-transaction (() &body body)
  `(lambdalite:with-tx
     ,@body))

(defvar *rowvar*)
(defmacro database:query (query-form)
  (if (eql query-form :all)
      `(constantly T)
      (let ((*rowvar* (gensym "ROW")))
        `(lambda (,*rowvar*)
           ,(compile-query query-form)))))

(defun gencomp (a b numcomp stringcomp)
  (etypecase a
    (number (funcall numcomp a b))
    (string (funcall stringcomp a b))))

(defun compile-query (form)
  (etypecase form
    (null (error "NIL not allowed"))
    ((or real string symbol) form)
    (character (string form))
    (list
     (flet ((gencomparator (numcomp stringcomp)
              `(gencomp ,(compile-query (second form))
                        ,(compile-query (third form))
                        ,numcomp ,stringcomp)))
       (case (first form)
         (:= `(equal ,(compile-query (second form))
                     ,(compile-query (third form))))
         (:!= (compile-query `(:not (:= ,@(cdr form)))))
         (:> (gencomparator #'> #'string>))
         (:< (gencomparator #'< #'string<))
         (:<= (gencomparator #'< #'string<=))
         (:>= (gencomparator #'>= #'string>=))
         (:MATCHES `(cl-ppcre:scan ,(compile-query (third form))
                                   ,(compile-query (second form))))
         (:IN `(find ,(compile-query (second form))
                     (list ,@(mapcar #'compile-query (cddr form)))
                     :test #'equal))
         (:AND `(and ,@(mapcar #'compile-query (cdr form))))
         (:OR `(or ,@(mapcar #'compile-query (cdr form))))
         (:NOT `(not ,(compile-query (second form))))
         (:FIELD `(getf ,*rowvar* ,(ensure-keyword (second form))))
         (QUOTE (compile-query `(:FIELD ,(second form))))
         (T form))))))
