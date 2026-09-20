(in-package #:meow)

(defun %stamp (file)
  "A key for FILE's contents, or nil if it cannot be read. FILE-WRITE-DATE
has one-second resolution, too coarse for an edit made while a poll runs, so
this reads the file."
  (ignore-errors
   (with-open-file (stream file)
     (let* ((buffer (make-string (file-length stream)))
            (count (read-sequence buffer stream)))
       (cons count (sxhash (subseq buffer 0 count)))))))
