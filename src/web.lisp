;;; Biochat work with GEO datasets
;;; see LICENSE file for permissions

(in-package :b42)
(named-readtables:in-readtable rutilsx-readtable)


(defvar *hunch* (hunch:start-web 3344))
 
(defparameter *geo-sim-methods*
  '((tfidf-sim "TFIDF similarity")
    (bm25-sim "BM25 similarity - a variant of TFIDF")
    (cos-sim "Cosine similarity of document vectors")
    (euc-sim "Euclidian distance-based similarity of document vectors")
    (eucos-sim "Euclidian-cosine averaged similarity")
    (smoothed-cos-sim "Smoothed cosine similarity")
    #+nil (wn-sim "Pubmed Wordnet-based similarity of documents")))

(defparameter *geo-sim-filters*
  '((:histone "Same histone")
    (:organism "Same organism")
    (:libstrats "Same sequencing type")))

(defvar *search-cache* #h(equalp))


;;; urls

(url "/static/:file" (file)
  (htt:handle-static-file (local-file (fmt "web/static/~A" file))))

(url "/" ()
  (who:with-html-output-to-string (out)
    (:html
     (:head
      (:title "Biochat")
      (:link :href "/static/style.css" :rel "stylesheet" :type "text/css")
      (:script :type "text/javascript" :src "/static/jquery-1.11.3.js" "")
      (:script :type "text/javascript" :src "/static/spin.js" "")
      (:script :type "text/javascript" :src "/static/main.js" "")
      (:script :type "text/javascript"
               "$(document).ready(function () {
                   $('input[name=simmethods]:first').attr('checked', true);
                });"))
     (:body
      (:div :class "page" :id "page"
            (:div :style "margin-top: 40px;"
             (:img :style "margin-right: 20px; width: 100px; float: left;"
                   :src "/static/logo.png")
             (:div :style "color: gray;"
                   "Here, you can find the most similar records from the "
                   (:a :href "https://www.ncbi.nlm.nih.gov/geo/" "GEO DB")
                   ". To do that, you have to put in a particular record's ID "
                   "(and optionally select the number of similar records to show)."
                   (:br)
                   "For instance, in record "
                   "https://www.ncbi.nlm.nih.gov/sites/GDSbrowser?acc=GDS5879 "
                   "the input number is GDS5879."
                   (:br)
                   "The GSE records are also supported: "
                   "enter GSE425 for https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE425."))
            (:hr :color "white" :width "100%")
            (:form :action "/search" :method "GET" :id "search-form"
                   :onsubmit "return search()"
                   (:label :for "gid" "Enter GEO record id:") " "
                   (:input :type "text" :name "gid" :id "gid" :size "30") " "
                   (:label :for "count" "count:") " "
                   (:input :type "text" :name "count" :id "count" :size "3"
                           :value "10")
                   (:br)
                   (:div :class "box" :id "sim-methods"
                    "Choose similarity methods:" (:br)
                    (loop :for (method desc) :in *geo-sim-methods* :do
                      (who:htm
                       (:input :type :radio :name "simmethods" :value method)
                       (:label :for "simmethods" (who:str desc))
                       (:br))))
                   (:div :class "box" :id "sim-filters"
                    "Choose additional filters:" (:br)
                    (loop :for (filter desc) :in *geo-sim-filters* :do
                      (who:htm
                       (:input :type :checkbox
                               :value filter :name "sim-filters")
                       (:label :for "sim-filters"
                               (who:str desc))
                       (:br))))
                   (:div :class "box" :id "sim-organisms"
                         "Look only in these organisms: "
                         (:a :href "#" :onclick "return toggle_simorganisms()"
                             :class "black"
                             "▼")
                         (:br)
                         (:div :id "simorganisms"
                          ;; TODO: also try to use somehow the hordes of GSE organisms
                          (loop :for organism :in (? *geo-organisms* :gds) :do
                            (who:htm
                             (:div :class "organisms-box"
                              (:input :type :checkbox
                                      :value organism :name "sim-organisms")
                              (:label :for "sim-organisms" :class "spacelabel"
                                      (who:str organism)))
                             " "))))
                   (:div :class "box" :id "sim-libstrats"
                         "Look only in these library strategies: "
                         (:a :href "#" :onclick "return toggle_simlibstrats()"
                             :class "black"
                             "▼")
                         (:br)
                         (:div :id "simlibstrats"
                               (loop :for strat :in *geo-libstrats* :do
                                 (who:htm
                                  (:div :class "organisms-box"
                                        (:input :type :checkbox :value strat
                                                :name "sim-libstrats")
                                        (:label :for "sim-libstrats"
                                                :class "spacelabel"
                                                (who:str strat)))
                                  " "))))
                   (:div (:input :type "submit" :value "Search")))
            (:br)
            (:div :id "search-results" ""))))))

(url "/search" (gid sim-methods sim-filters sim-organisms sim-libstrats
                (count :parameter-type 'integer :init-form 10))
  (flet ((not-found ()
           (who:with-html-output-to-string (out)
             (who:fmt "No record with ID ~A found in GEO database." gid))))
    (if (< (length gid) 4)
        (not-found)
        (with ((type (mkeyw (slice gid 0 3)))
               (id (parse-integer (slice gid 3) :junk-allowed t))
               (db *geo-db*)
               (vecs *geo-vecs*)
               (same-histone (? *geo-same-histones* type))
               (methods (mapcar ^(mksym % :package :b42)
                                (split #\, sim-methods :remove-empty-subseqs t)))
               (sim-filters (mapcar 'mkeyw (split #\, sim-filters
                                                  :remove-empty-subseqs t)))
               (org-filters (split #\, sim-organisms :remove-empty-subseqs t))
               (str-filters (mapcar 'mkeyw (split #\, sim-libstrats
                                                  :remove-empty-subseqs t)))
               (filters (append sim-filters
                                org-filters
                                str-filters)))
          (if-it (find id db :key 'gr-id)
                 (who:with-html-output-to-string (out)
                   (:div "Requested record:")
                   (who:str (format-geo-rec it))
                   (:hr)
                   (:div "Closest records:")
                   (:ol (let ((*geo-db* db)
                              (*geo-vecs* vecs))
                          (when filters
                            (let (db vecs)
                              (dotimes (i (length *geo-db*))
                                (let ((cand (? *geo-db* i)))
                                  (when (match-records it cand
                                                       sim-filters
                                                       org-filters
                                                       str-filters
                                                       same-histone)
                                    (push cand db)
                                    (push (? *geo-vecs* i) vecs))))
                              (:= *geo-db* (coerce db 'vector))
                              (:= *geo-vecs* (coerce vecs 'vector))))
                          (loop :for (r m s)
                                :in (find-closest-recs it count
                                                       :methods methods
                                                       :filters filters) :do
                            (who:htm (:li (who:str (format-geo-rec
                                                    r m s
                                                    #h(:score s
                                                       :methods sim-methods
                                                       :filters sim-filters
                                                       :organisms sim-organisms
                                                       :libstrats sim-libstrats)
                                                    @it.id))))))))
                 (not-found))))))

(url "/interest" (tid oid params)
  (let ((params (yason:parse params)))
    (dotable (key val params)
      (when (blankp val) (rem# key params)))
    (:= tid (string-upcase tid))
    (:= oid (string-upcase oid))
    (if (eql :PUT (htt:request-method*))
        (if (and tid oid (not (string= tid oid)))
            (psql:with-connection *psql*
              (psql:query (:insert-into 'interest :set 'tid tid 'oid oid
                                        'ip (htt:header-in* "X-Forwarded-For")
                                        'params (json:encode-json-to-string
                                                 params)))
              "OK")
            (abort-request htt:+http-bad-request+))
        (abort-request htt:+http-method-not-allowed+))))

;;; utils

(defun format-geo-rec (rec &optional method score params match-id)
  (who:with-html-output-to-string (out)
    (:div :class "geo-rec"
          (:div (who:fmt "# ~A~A - ~A (~A)~@[ / ~A~]~@[: ~A~]"
                         @rec.type @rec.id @rec.title @rec.organism
                         (when-it (car (assoc1 method *geo-sim-methods*))
                           (let ((method (strjoin #\Space (take 3 (re:split
                                                                   "\\b" it)))))
                             (switch (method :test 'string=)
                               ("TFIDF" "TF-IDF")
                               (otherwise (string-downcase method)))))
                         score))
          (:blockquote
           (who:str @rec.summary)
           (:div (:span :class "grey" "Platform: ") (who:str @rec.platform)
                 (:br)
                 (:span :class "grey" "Citations: ")
                 (let ((onclick (if match-id
                                    (fmt "track_interest(\"~A~A\", \"~A~A\", ~A)"
                                         @rec.type match-id @rec.type @rec.id
                                         (json:encode-json-to-string params))
                                    ""))
                       (pmids (mapcar ^(ignore-errors (parse-integer %))
                                      (split #\, @rec.citations))))
                   (cond-it
                     ((every 'numberp pmids)
                      (dolist (pmid pmids)
                        (who:htm
                         (:a :href (fmt "https://www.ncbi.nlm.nih.gov/pubmed/~A"
                                        pmid)
                             :onclick onclick
                             (who:fmt "PMID ~A" pmid)) " ")))
                     ((with ((pmid-pos (search "PMID" @rec.citations))
                             (pmid-beg (position-if 'digit-char-p @rec.citations
                                                    :start (+ (or pmid-pos 0) 4))))
                        (when (and pmid-pos pmid-beg
                                   (not (some 'alpha-char-p
                                              (slice @rec.citations
                                                     (+ pmid-pos 4) pmid-beg))))
                          (pair pmid-beg
                                (position-if-not 'digit-char-p @rec.citations
                                                 :start pmid-beg))))
                      (let ((pmid (apply 'slice @rec.citations it)))
                        (who:htm
                         (who:str (slice @rec.citations 0 (lt it)))
                         (:a :href (fmt "https://www.ncbi.nlm.nih.gov/pubmed/~A"
                                        pmid)
                             :target "_blank"
                             :onclick onclick
                             (who:fmt "~A" pmid))
                         (when (rt it)
                           (who:str (slice @rec.citations (rt it)))))))
                     (t
                      (who:str @rec.citations)))
                   (who:htm
                    (:br)
                    (:span :class "grey" "Sequencing type: ")
                    (who:str (if @rec.microarrayp "microarray" "other")))
                   (when-it @rec.libstrats
                     (who:htm
                      (:br)
                      (:span :class "grey" "Library strategies: ")
                      (dolist (libstrat it)
                        (who:fmt "~(~A~) " (symbol-name libstrat)))))))))))
  
(defun find-closest-recs (rec count &key
                                      (methods (mapcar 'first *geo-sim-methods*))
                                      filters)
  (getset#
   (list @rec.id count methods filters)
   *search-cache*
   (mapcar ^(list (lt (lt %))
                  (rt %)
                  (rt (lt %)))
           (take count
                 (sort (remove-duplicates
                        (take (* 2 count)
                              (append
                               (reduce 'append
                                       (mapcar (lambda (method)
                                                 (when (member method methods)
                                                   (mapcar ^(pair % method)
                                                           (vec-closest-recs
                                                            rec :measure method))))
                                               '(cos-sim euc-sim eucos-sim
                                                 smoothed-cos-sim)))
                               (reduce 'append
                                       (mapcar (lambda (method)
                                                 (when (member method methods)
                                                   (map 'list ^(pair % method)
                                                        (tok-closest-recs
                                                         rec :measure method))))
                                               '(tfidf-sim bm25-sim)))))
                        :key 'lt)
                       '> :key (=> rt lt))))))

(defun match-records (rec cand sim-filters org-filters str-filters
                      same-histone-recs)
  (and (every 'true
              (mapcar ^(case %
                         (:histone
                          (if-it (? same-histone-recs rec)
                                 (member cand it)
                                 t))
                         (:organism
                          (string= @rec.organism @cand.organism))
                         (:libstrats
                          (cond (@rec.microarrayp @cand.microarrayp)
                                (@rec.libstrats (intersection @rec.libstrats
                                                              @cand.libstrats))
                                (t (null (or @cand.microarrayp
                                             @cand.libstrats))))))
                      sim-filters))
       (or (null org-filters)
           (member @cand.organism org-filters :test 'string=))
       (or (null str-filters)
           (and (member :microarray str-filters) @cand.microarrayp)
           (intersection @rec.libstrats str-filters :test 'string-equal))))
