;;;
;;; compile.scm - The compiler
;;;
;;;   Copyright (c) 2004-2005 Shiro Kawai, All rights reserved.
;;;   
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;  
;;;  $Id: compile.scm,v 1.6 2005-04-22 23:12:10 shirok Exp $
;;;

(define-module gauche.internal
  (use srfi-2)
  (use util.match)
  )
(select-module gauche.internal)

;;; THE COMPILER
;;;
;;;   The main entry point is COMPILE, defined under "Entry point" section.
;;;
;;;     compile :: Sexpr, Module -> CompiledCode
;;;
;;;   Gauche compiles programs at runtime, so we don't want to spend too
;;;   much time in compilation, while we still want to generate as efficient
;;;   code as possible.
;;;
;;; Structure of the compiler
;;;
;;;   We have 3 passes.  Here are the outlines.  See the header of each
;;;   section for the details.
;;;
;;;   Pass 1 (Parsing):
;;;     - Converts Sexpr into an intermediate form (IForm).
;;;     - Macros and global inlinable functions are expanded.
;;;     - Global constant variables are substituted to its value.
;;;     - Variable bindings are analyzed.  The # of references and
;;;       modifications of each local variable are recorded.
;;;     - Constant folding #1.
;;;
;;;   Pass 2 (Optimization):
;;;     - Traverses IFrom and modify the tree to optimize it.
;;;     - Limited beta-sustitution (local variable substitution and
;;;       inline local functions for the obvious cases).
;;;     - Closure analysis (track the usage of local variables and
;;;       closures, and adds marks to the IForm nodes).
;;;     - Constant folding #2.
;;;
;;;   Pass 3 (Code generation):
;;;     - Traverses IForm and generate VM instructions.
;;;     - Perform instruction combining.
;;;     - Perform simple-minded jump optimization.
;;;

;;=====================================================================
;; Compile-time constants
;;

(eval-when (:compile-toplevel)
  (define-constant LEXICAL 0)
  (define-constant SYNTAX  1)
  (define-constant PATTERN 2))

(define-macro (define-enum name . syms)
  (let1 alist '()
    `(eval-when (:compile-toplevel)
       ,@(let loop ((syms syms) (i 0))
           (if (null? syms)
             '()
             (begin
               (push! alist (cons (car syms) i))
               (cons `(define-constant ,(car syms) ,i)
                     (loop (cdr syms) (+ i 1))))))
       (define-constant ,name ',(reverse! alist)))))

(define-enum .intermediate-tags.
  $DEFINE
  $LREF
  $LSET
  $GREF
  $GSET
  $CONST
  $IF
  $LET
  $RECEIVE
  $LAMBDA
  $LABEL
  $PROMISE
  $SEQ
  $CALL
  $ASM
  $CONS
  $APPEND
  $VECTOR
  $LIST->VECTOR
  $LIST
  $LIST*
  $MEMV
  $EQ?
  $EQV?
  $IT
  )

;; Define constants for VM instructions.
;; This is a BLACK MAGIC.  Not recommended as a general trick.
(eval-when (:compile-toplevel)
  (define *insn-counter* 0)
  (define *insn-alist* '())
  (define-macro (define-insn name . _)
    (let1 num *insn-counter*
      (inc! *insn-counter*)
      (push! *insn-alist* (cons name num))
      `(define-constant ,name ,num)))
  (load "vminsn.scm")
  (define-constant .insn-alist. (reverse! *insn-alist*))
  )

;; Maximum size of $LAMBDA node we allow to duplicate and inline.
(define-constant SMALL_LAMBDA_SIZE 12)

;;;============================================================
;;; Utility macro
;;;

;; We use integers, instead of symbols, as tags, for it allows
;; us to use jump table rather than 'case'. 

(define-macro (case/unquote obj . clauses)
  (let1 tmp (gensym)
    (define (expand-clause clause)
      (match clause
        (((item) . body)
         `((eqv? ,tmp ,item) ,@body))
        (((item ...) . body)
         `((memv ,tmp (list ,@item)) ,@body))
        (('else . body)
         `(else ,@body))))
    `(let ((,tmp ,obj))
       (cond ,@(map expand-clause clauses)))))

;;============================================================
;; Data structures
;;

;; NB: for the time being, we use a simple vector and manually
;; defined accessors/modifiers.  Partly because we can't use
;; define-class stuff here until we can compile gauche/object.scm
;; into C, and partly because using inlined vector-{ref|set!} is
;; pretty fast compared to the generic class access.  Probably we
;; should provide a common way to define a simple structure which
;; allows the compiler to inline accessors for performance, trading
;; off the runtime flexibility.

;; Macro define-simple-struct creates a bunch of functions and macros
;; to emulate a structure by a vector.
;; NAME is a symbol to name the structure type.  TAG is some value
;; (usually a symbol or an integer) to indicate the type of the
;; structure.
;;
;; (define-simple-struct <name> <tag> <constructor> [<predicate> (<slot-spec>*)])
;;
;; <constructor> : (<constructor-name> <slot-name> ...) | #f
;; <predicate>   : <symbol> | #f
;; <slot-spec>   : (<slot-name> [<init-value>]) | <slot-name>
;;
;; For each <slot-spec>, the following accessor/modifier are automatially
;;
;;   NAME-SLOT      - accessor (macro)
;;   NAME-SLOT-set! - modifier (macro)
;;
;; Arguments for the constructor is specified by <constructor> clause.
;; It lists the slot names that should be given to the constructor.
;; The slots which is not listed in INITARGS are initilialized by its
;; INIT-VALUE, or #f if INIT-VALUE isn't specified.
;;
;; If <slot-spec>s are omitted, the constructor arguments are used as
;; slot names.
;;
(define-macro (define-simple-struct name tag constructor . opts)
  (let-optionals* opts ((predicate #f)
                       (slots (cdr constructor)))
    `(begin
       ,@(if constructor
           (let ((constructor-name (car constructor))
                 (initializer (map (lambda (s)
                                     (receive (n v)
                                         (if (pair? s)
                                           (values (car s) (cdr s))
                                           (values s '()))
                                       (cond ((memq n (cdr constructor)) n)
                                             ((null? v) #f)
                                             (else (car v)))))
                                   slots))
                 )
             `((define-inline (,constructor-name ,@(cdr constructor))
                 (vector ,tag ,@initializer))))
           '())
       ,@(if predicate
           `((define (,predicate obj)
               (and (vector? obj) (eqv? (vector-ref obj 0) ,tag))))
           '())
       ,@(let loop ((s slots) (i 1) (r '()))
           (if (null? s)
             (reverse! r)
             (let* ((slot-name (if (pair? (car s)) (caar s) (car s)))
                    (acc (string->symbol #`",|name|-,|slot-name|"))
                    (mod (string->symbol #`",|name|-,|slot-name|-set!")))
               (loop (cdr s)
                     (+ i 1)
                     (list*
                      `(define-macro (,acc obj)
                         `(vector-ref ,obj ,,i))
                      `(define-macro (,mod obj val)
                         `(vector-set! ,obj ,,i ,val))
                      r))))))
    ))

(define-inline (variable? arg)
  (or (symbol? arg) (identifier? arg)))

;; Local variables (lvar)
;;
;;   Slots:
;;     name  - name of the variable (symbol)
;;     initval   - initialized value
;;     ref-count - in how many places this variable is referefnced?
;;     set-count - in how many places this variable is set!
;;

(define-simple-struct lvar 'lvar
  (make-lvar name) lvar?
  ((name)
   (initval (undefined))
   (ref-count 0)
   (call-count 0) ;; will be gone
   (set-count 0)))

(define (lvar-ref++! var)
  (lvar-ref-count-set! var (+ (lvar-ref-count var) 1)))
(define (lvar-ref--! var)
  (lvar-ref-count-set! var (- (lvar-ref-count var) 1)))
(define (lvar-set++! var)
  (lvar-set-count-set! var (+ (lvar-set-count var) 1)))

;; Compile-time environment (cenv)
;;
;;   Slots:
;;     module   - The 'current-module' to resolve global binding.
;;     frames   - List of local frames.  Each local frame has a form:
;;                (<type> (<name> . <obj>) ...)
;;
;;                <type>     <obj>
;;                ----------------------------------------------
;;                0          <lvar>     ;; lexical binding
;;                1          <macro>    ;; syntactic binding
;;                2          <pvar>     ;; pattern variable
;;
;;                Constants LEXICAL, SYNTAX and PATTERN are defined
;;                to represent <type> for the convenience.
;;
;;     exp-name - The "name" of the current expression, that is, the
;;                name of the variable the result of the current 
;;                expression is to be bound.  This slot may contain
;;                an identifier (for global binding) or a lvar (for
;;                local binding).   This slot may be #f.
;;
;;     current-proc - Holds the information of the current
;;                compilig procedure.  It accumulates information needed
;;                in later stages for the optimization.  This slot may
;;                be #f.
;;
;; NB: this structure is assumed by cenv-lookup, defined in compaux.c.
;; If you change this structure here, adjust compaux.c accordingly.

(define-simple-struct cenv 'cenv
  (make-cenv module frames exp-name) #f
  (module frames exp-name current-proc))

(define (cenv-copy cenv) (vector-copy cenv))

(define (make-bottom-cenv . maybe-module)
  (make-cenv (get-optional maybe-module (vm-current-module)) '() #f))

(define-macro (%cenv-copy/update cenv . updates)
  (let1 new (gensym)
    `(let1 ,new (cenv-copy ,cenv)
       ,@(let loop ((updates updates) (r '()))
           (if (null? updates)
             (reverse! r)
             (let1 setter (string->symbol #`",(car updates)-set!")
               (loop (cddr updates)
                     (cons `(,setter ,new ,(cadr updates)) r)))))
       ,new)))

(define (cenv-swap-module cenv mod)
  (%cenv-copy/update cenv cenv-module mod))

(define (cenv-extend cenv frame type)
  (%cenv-copy/update cenv cenv-frames (acons type frame (cenv-frames cenv))))

(define (cenv-extend/proc cenv frame type proc)
  (%cenv-copy/update cenv
                     cenv-frames (acons type frame (cenv-frames cenv))
                     cenv-current-proc proc))

(define (cenv-add-name cenv name)
  (%cenv-copy/update cenv cenv-exp-name name))

(define (cenv-sans-name cenv)
  (if (cenv-exp-name cenv)
    (%cenv-copy/update cenv cenv-exp-name #f)
    cenv))

(define (cenv-extend/name cenv frame type name)
  (%cenv-copy/update cenv
                     cenv-frames  (acons type frame (cenv-frames cenv))
                     cenv-exp-name name))

;; toplevel environment == cenv has only syntactic frames
(define (cenv-toplevel? cenv)
  (not (any (lambda (frame) (eqv? (car frame) LEXICAL)) (cenv-frames cenv))))

;; Intermediate tree form (IForm)
;;
;;   We first convert the program into an intermediate tree form (IForm),
;;   which is in principle similar to A-normal form, but has more
;;   convenience node types specific to our VM.   IForm is represented
;;   by a nested vectors, whose first element shows the type of the node.
;;
;; <top-iform> :=
;;    <iform>
;;    #($define <o> <flags> <id> <iform>)
;;
;; <iform> :=
;;    #($lref <lvar>)        ;; local variable reference
;;    #($lset <lvar> <iform>) ;; local variable modification
;;    #($gref <id>)          ;; global variable reference
;;    #($gset <id> <iform>)   ;; global variable modification
;;    #($const <obj>)        ;; constant literal
;;    #($if <o> <iform> <iform+> <iform+>) ;; branch
;;    #($let <o> <type> (<lvar> ...) (<iform> ...) <iform>) ;; local binding
;;                           ;; type : 'let | 'rec
;;    #($receive <o> <reqarg> <optarg> (<lvar> ...) <iform> <iform>)
;;                           ;; local binding (mv)
;;    #($lambda <o> <name> <reqarg> <optarg> (<lvar> ...) <iform> <flag>)
;;                           ;; closure
;;                           ;; <flag> : #f, inlined, rec, local
;;    #($label <o> <label> <iform>) ;; merge point of local call.  see below.
;;    #($promise <o> <expr>) ;; promise
;;    #($seq (<iform> ...))   ;; sequencing
;;    #($call <o> <proc-expr> (<arg-expr> ...) <flag>) ;; procedure call
;;                           ;; <flag> may be #f or 'tail-local
;;
;;    #($asm <o> <insn> (<arg> ...)) ;; inline assembler
;;
;;    #($cons <o> <ca> <cd>)       ;; used in quasiquote
;;    #($append <o> <ca> <cd>)     ;; ditto
;;    #($vector <o> (<elt> ...))   ;; ditto
;;    #($list->vector <o> <list>)  ;; ditto
;;    #($list <o> (<elt> ...))     ;; ditto
;;    #($list* <o> (<elt> ...))    ;; ditto
;;    #($memv <o> <obj> <list>)    ;; used in case
;;    #($eq?  <o> <x> <y>)         ;; ditto
;;    #($eqv? <o> <x> <y>)         ;; ditto
;;
;; <iform+> :=
;;    <iform>
;;    #($it)                 ;; refer to the value in the last test clause.
;;
;;  NB: <o> is the original form, used to generate debug info.
;;      if the intermediate form doesn't have corresponding original
;;      form, it will be #f.
;;
;;  NB: the actual value of the first element is an integer instead of
;;      a symbol, which allows pass3/rec to use vector dispatch instead
;;      of case statement.
;;
;;  NB: The nodes are destructively modified during compilation, in order
;;      to keep allocations minimal.   Nodes shouldn't be shared, for
;;      side-effects may vary depends on the path to the node.  The only
;;      exception is $label node.
;;
;;  NB: $label IForm is introduced in Pass2 to record the shared node.
;;      It marks the destination of LOCAL-ENV-JUMP, and also is created
;;      during $if optimization.  The <label> slot of
;;      $label IForm is filled in Pass3 to record the label number within
;;      the compiled code vector; in Pass2 it is #f.

(define-macro (iform-tag iform)
  `(vector-ref ,iform 0))

;; check intermediate tag
(define-macro (has-tag? iform tag)
  `(eqv? (vector-ref ,iform 0) ,tag))

;; intermediate form definitions

(define-simple-struct $define $DEFINE ($define src flags id expr))

(define-simple-struct $lref $LREF #f #f (lvar))
(define-inline ($lref lvar)
  (lvar-ref++! lvar) (vector $LREF lvar))

(define-simple-struct $lset $LSET #f #f (lvar expr))
(define-inline ($lset lvar expr)
  (lvar-set++! lvar) (vector $LSET lvar expr))

(define-simple-struct $gref $GREF ($gref id))

(define-simple-struct $gset $GSET ($gset id expr))

(define-simple-struct $const $CONST ($const value))

(define $const-undef ;; common case
  (let1 x ($const (undefined)) (lambda () x)))
(define $const-nil
  (let1 x ($const '()) (lambda () x)))

(define-simple-struct $if $IF ($if src test then else))

(define-simple-struct $let $LET ($let src type lvars inits body))

(define-simple-struct $receive $RECEIVE
  ($receive src reqargs optarg lvars expr body))

(define-simple-struct $lambda $LAMBDA
  ($lambda src name reqargs optarg lvars body flag) #f
  (src name reqargs optarg lvars body flag
       ;; The following slot(s) is/are used temporarily during pass2, and
       ;; need not be saved when packed.
       (calls '())      ;; list of call sites
       (free-lvars '()) ;; list of free local variables
       ))

(define-simple-struct $label $LABEL ($label src label body))

(define-simple-struct $seq $SEQ #f #f (body))
(define-inline ($seq exprs)
  (if (and (pair? exprs) (null? (cdr exprs)))
    (car exprs)
    (vector $SEQ exprs)))

(define-simple-struct $call $CALL ($call src proc args flag))

(define-simple-struct $asm $ASM ($asm src insn args))

(define-simple-struct $promise $PROMISE ($promise src expr))

(define-simple-struct $cons $CONS #f #f (arg0 arg1))

;; quasiquote tends to generate nested $cons, which can be
;; packed to $list or $list*.
(define ($cons o x y)
  (if (has-tag? y $CONS)
    (receive (type elts) ($cons-pack y)
      (vector type o (cons x elts)))
    (vector $CONS o x y)))

(define ($cons-pack elt)
  (cond
   ((equal? elt ($const-nil)) (values $LIST '()))
   ((has-tag? elt $CONS)
    (receive (type elts) ($cons-pack (vector-ref elt 3))
      (values type (cons (vector-ref elt 2) elts))))
   (else (values $LIST* (list elt)))))

(define-simple-struct $append $APPEND ($append src arg0 arg1))
(define-simple-struct $memv   $MEMV   ($memv src arg0 arg1))
(define-simple-struct $eq?    $EQ?    ($eq? src arg0 arg1))
(define-simple-struct $eqv?   $EQV?   ($eqv? src arg0 arg1))
(define-simple-struct $vector $VECTOR ($vector src args))
(define-simple-struct $list   $LIST   ($list src args))
(define-simple-struct $list*  $LIST*  ($list* src args))
(define-simple-struct $list->vector $LIST->VECTOR  ($list->vector src arg0))

(define $it (let ((c `#(,$IT))) (lambda () c)))

;; common accessors
(define-macro ($*-src  iform)  `(vector-ref ,iform 1))
(define-macro ($*-args iform)  `(vector-ref ,iform 2))
(define-macro ($*-arg0 iform)  `(vector-ref ,iform 2))
(define-macro ($*-arg1 iform)  `(vector-ref ,iform 3))
(define-macro ($*-args-set! iform val)  `(vector-set! ,iform 2 ,val))
(define-macro ($*-arg0-set! iform val)  `(vector-set! ,iform 2 ,val))
(define-macro ($*-arg1-set! iform val)  `(vector-set! ,iform 3 ,val))

;; look up symbolic name of iform tag (for debugging)
(define (iform-tag-name tag)
  (let loop ((p .intermediate-tags.))
    (cond ((null? p) #f)
          ((eqv? (cdar p) tag) (caar p))
          (else (loop (cdr p))))))

;; look up symbolic name of VM instruction (for debugging)
;; (The proper way to realize this is using gauche.vm.insn, but we can't
;;  use it from comp.scm)
(define (insn-name code)
  (let loop ((p .insn-alist.))
    (cond ((null? p) #f)
          ((eqv? (cdar p) code) (caar p))
          (else (loop (cdr p))))))

;; prettyprinter of intermediate form
(define (pp-iform iform)

  (define labels '()) ;; alist of label node and count

  (define (indent count)
    (dotimes (i count) (write-char #\space)))

  (define (nl ind)
    (newline) (indent ind))

  (define (id->string id)
    (symbol->string (slot-ref id 'name)))

  (define (lvar->string lvar)
    (format "~a[~a;~a]" (variable-name (lvar-name lvar))
            (lvar-ref-count lvar) (lvar-set-count lvar)))
  
  (define (rec ind iform)
    (case/unquote
     (iform-tag iform)
     (($DEFINE) 
      (format #t "($define ~a ~a" ($define-flags iform)
              (id->string ($define-id iform)))
      (nl (+ ind 2))
      (rec (+ ind 2) ($define-expr iform)) (display ")"))
     (($LREF)
      (format #t "($lref ~a)" (lvar->string ($lref-lvar iform))))
     (($LSET)
      (format #t "($lset ~a"  (lvar->string ($lset-lvar iform)))
      (nl (+ ind 2))
      (rec (+ ind 2) ($lset-expr iform)) (display ")"))
     (($GREF)
      (format #t "($gref ~a)" (id->string ($gref-id iform))))
     (($GSET)
      (format #t "($gset ~a" (id->string ($gset-id iform)))
      (nl (+ ind 2))
      (rec (+ ind 2) ($gset-expr iform)) (display ")"))
     (($CONST)
      (format #t "($const ~s)" ($const-value iform)))
     (($IF)
      (display "($if ")
      (rec (+ ind 5) ($if-test iform)) (nl (+ ind 2))
      (rec (+ ind 2) ($if-then iform)) (nl (+ ind 2))
      (rec (+ ind 2) ($if-else iform)) (display ")"))
     (($LET)
      (let* ((hdr  (format "($let~a (" (case ($let-type iform)
                                         ((let) "") ((rec) "rec"))))
             (xind (+ ind (string-length hdr))))
        (display hdr)
        (for-each (lambda (var init)
                    (let1 z (format "(~a " (lvar->string var))
                      (display z)
                      (rec (+ xind  (string-length z)) init)
                      (display ")")
                      (nl xind)))
                  ($let-lvars iform) ($let-inits iform))
        (display ")") (nl (+ ind 2))
        (rec (+ ind 2) ($let-body iform)) (display ")")))
     (($RECEIVE)
      (format #t "($receive ~a" (map lvar->string ($receive-lvars iform)))
      (nl (+ ind 4))
      (rec (+ ind 4) ($receive-expr iform)) (nl (+ ind 2))
      (rec (+ ind 2) ($receive-body iform)) (display ")"))
     (($LAMBDA)
      (format #t "($lambda[~a;~a] ~a" ($lambda-name iform)
              (length ($lambda-calls iform))
              (map lvar->string ($lambda-lvars iform)))
      (nl (+ ind 2))
      (rec (+ ind 2) ($lambda-body iform)) (display ")"))
     (($LABEL)
      (cond ((assq iform labels)
             => (lambda (p) (format #t "label#~a" (cdr p))))
            (else
             (let1 num (length labels)
               (push! labels (cons iform num))
               (format #t "($label #~a" num)
               (nl (+ ind 2))
               (rec (+ ind 2) ($label-body iform)) (display ")")))))
     (($SEQ)
      (format #t "($seq")
      (for-each (lambda (node) (nl (+ ind 2)) (rec (+ ind 2) node))
                ($seq-body iform))
      (display ")"))
     (($CALL)
      (let1 pre
          (cond (($call-flag iform) => (cut format "($call[~a] " <>))
                (else "($call "))
        (format #t pre)
        (rec (+ ind (string-length pre)) ($call-proc iform))
        (for-each (lambda (node) (nl (+ ind 2)) (rec (+ ind 2) node))
                  ($call-args iform))
        (display ")")))
     (($ASM)
      (let1 insn ($asm-insn iform)
        (format #t "($asm ~a" (cons (insn-name (car insn)) (cdr insn))))
      (for-each (lambda (node) (nl (+ ind 2)) (rec (+ ind 2) node))
                ($asm-args iform))
      (display ")"))
     (($PROMISE)
      (display "($promise ")
      (rec (+ ind 10) ($promise-expr iform))
      (display ")"))
     (($IT) (display "($it)"))
     (($CONS $APPEND $MEMV $EQ? $EQV?)
      (let* ((s (format "(~a " (iform-tag-name (iform-tag iform))))
             (ind (+ ind (string-length s))))
        (display s)
        (rec ind (vector-ref iform 2)) (nl ind)
        (rec ind (vector-ref iform 3)) (display ")")))
     (($LIST $LIST* $VECTOR)
      (display (format "(~a " (iform-tag-name (iform-tag iform))))
      (for-each (lambda (elt) (nl (+ ind 2)) (rec (+ ind 2) elt))
                (vector-ref iform 2)))
     (($LIST->VECTOR)
      (display "($LIST->VECTOR ")
      (rec (+ ind 14) (vector-ref iform 2))
      (display ")"))
     (else
      (error "pp-iform: unknown tag:" (iform-tag iform)))
     ))

  (rec 0 iform)
  (newline))

;; Sometimes we need to save IForm for later use (e.g. procedure inlining)
;; We pack an IForm into a vector, instead of keeping it as is, since:
;;  - For separate compilation, the saved form has to become a static
;;    literal, keeping it's topology.  The compiler unifies equal?-literals,
;;    so we can't just rely on it.  We also need to traverse the IForm to
;;    make sure everything is serializable, anyway.
;;  - IForm is destructively modified by pass 2, so we need to copy it
;;    every time it is used.
;;
;; Packed IForm is a vector, with the references are represented by indices.

(define (pack-iform iform)

  (define dict (make-hash-table 'eq?))
  (define r '())
  (define c 1)

  (define (put! iform . objs)
    (let1 head c
      (hash-table-put! dict iform head)
      (dolist (obj objs) (push! r obj) (inc! c))
      head))

  (define (get-ref iform)
    (or (hash-table-get dict iform #f) (pack-iform-rec iform)))

  (define (pack-iform-rec iform)
    (case/unquote
     (iform-tag iform)
     (($DEFINE)
      (put! iform $DEFINE ($*-src iform)
            ($define-flags iform) ($define-id iform)
            (get-ref ($define-expr iform))))
     (($LREF)
      (put! iform $LREF (get-ref ($lref-lvar iform))))
     (($LSET)
      (put! iform $LSET
            (get-ref ($lset-lvar iform)) (get-ref ($lset-expr iform))))
     (($GREF)
      (put! iform $GREF ($gref-id iform)))
     (($GSET)
      (put! iform $GSET ($gset-id iform) (get-ref ($gset-expr iform))))
     (($CONST)
      (put! iform $CONST ($const-value iform)))
     (($IF)
      (put! iform $IF ($*-src iform)
            (get-ref ($if-test iform))
            (get-ref ($if-then iform))
            (get-ref ($if-else iform))))
     (($LET)
      (put! iform (iform-tag iform) ($*-src iform) ($let-type iform)
            (map get-ref ($let-lvars iform))
            (map get-ref ($let-inits iform))
            (get-ref ($let-body iform))))
     (($RECEIVE)
      (put! iform $RECEIVE ($*-src iform)
            ($receive-reqargs iform) ($receive-optarg iform)
            (map get-ref ($receive-lvars iform))
            ($receive-expr iform)
            ($receive-body iform)))
     (($LAMBDA)
      (put! iform $LAMBDA ($*-src iform)
            ($lambda-name iform) ($lambda-reqargs iform) ($lambda-optarg iform)
            (map get-ref ($lambda-lvars iform))
            (get-ref ($lambda-body iform))
            ($lambda-flag iform)))
     (($LABEL)
      (put! iform $LABEL ($*-src iform) #f (get-ref ($label-body iform))))
     (($SEQ)
      (put! iform $SEQ (map get-ref ($seq-body iform))))
     (($CALL)
      (put! iform $CALL ($*-src iform)
            (get-ref ($call-proc iform))
            (map get-ref ($call-args iform))
            ($call-flag iform)))
     (($ASM)
      (put! iform $ASM ($*-src iform)
            ($asm-insn iform)
            (map get-ref ($asm-args iform))))
     (($IT)
      (put! iform $IT))
     (($PROMISE)
      (put! iform $PROMISE ($*-src iform)
            (get-ref ($promise-expr iform))))
     (($CONS $APPEND $MEMV $EQ? $EQV?)
      (put! iform (iform-tag iform) ($*-src iform)
            (get-ref ($*-arg0 iform))
            (get-ref ($*-arg1 iform))))
     (($VECTOR $LIST $LIST*)
      (put! iform (iform-tag iform) ($*-src iform)
            (map get-ref ($*-args iform))))
     (($LIST->VECTOR)
      (put! iform (iform-tag iform) ($*-src iform)
            (get-ref ($*-arg0 iform))))
     (('lvar)
      (put! iform 'lvar (lvar-name iform)))
     (else
      (errorf "[internal-error] unknown IForm in pack-iform: ~S" iform))
     ))

  ;; main body of pack-iform
  (let* ((start (pack-iform-rec iform))
         (vec (make-vector c)))
    (do ((i (- c 1) (- i 1))
         (r r (cdr r)))
        ((null? r))
      (vector-set! vec i (car r)))
    (vector-set! vec 0 start)
    vec))

(define (unpack-iform ivec)
  (let-syntax ((V (syntax-rules ()
                    ((V ix) (vector-ref ivec ix))
                    ((V ix off) (vector-ref ivec (+ ix off)))))
               )
  
    (define dict (make-hash-table 'eqv?))

    (define (unpack-rec ref)
      (cond ((hash-table-get dict ref #f))
            (else
             (let1 body (unpack-body ref)
               (hash-table-put! dict ref body)
               body))))

    (define (unpack-body i)
      (case/unquote
       (V i)
       (($DEFINE)
        ($define (V i 1) (V i 2) (V i 3) (unpack-rec (V i 4))))
       (($LREF)
        ($lref (unpack-rec (V i 1))))
       (($LSET)
        ($lset (unpack-rec (V i 1)) (unpack-rec (V i 2))))
       (($GREF)
        ($gref (V i 1)))
       (($GSET)
        ($gset (V i 1) (unpack-rec (V i 2))))
       (($CONST)
        ($const (V i 1)))
       (($IF)
        ($if (V i 1)
             (unpack-rec (V i 2)) (unpack-rec (V i 3)) (unpack-rec (V i 4))))
       (($LET)
        ($let (V i 1) (V i 2)
              (map unpack-rec (V i 3)) (map unpack-rec (V i 4))
              (unpack-rec (V i 5))))
       (($RECEIVE)
        ($receive (V i 1) (V i 2) (V i 3)
                  (map unpack-rec (V i 4)) (unpack-rec (V i 5))
                  (unpack-rec (V i 6))))
       (($LAMBDA)
        ($lambda (V i 1) (V i 2) (V i 3) (V i 4)
                 (map unpack-rec (V i 5)) (unpack-rec (V i 6)) (V i 7)))
       (($LABEL)
        ($label (V i 1) (V i 2) (unpack-rec (V i 3))))
       (($SEQ)
        ($seq (map unpack-rec (V i 1))))
       (($CALL)
        ($call (V i 1) (unpack-rec (V i 2)) (map unpack-rec (V i 3)) (V i 4)))
       (($ASM)
        ($asm (V i 1) (V i 2) (map unpack-rec (V i 3))))
       (($PROMISE)
        ($promise (V i 1) (unpack-rec (V i 2))))
       (($IT) ($it))
       (($CONS $APPEND $MEMV $EQ? $EQV?)
        (vector (V i) (V i 1) (unpack-rec (V i 2)) (unpack-rec (V i 3))))
       (($VECTOR $LIST $LIST*)
        (vector (V i) (V i 1) (map unpack-rec (V i 2))))
       (($LIST->VECTOR)
        (vector (V i) (V i 1) (unpack-rec (V i 2))))
       (('lvar)
        (make-lvar (V i 1)))
       (else
        (errorf "[internal error] unpack-iform: ivec broken at ~a: ~S"
                i ivec))
       ))

    (unpack-rec (V 0))))

;; Counts the size (approx # of nodes) of the iform.
(define (iform-count-size-upto iform limit)
  (define (rec iform cnt)
    (letrec-syntax ((sum-items
                     (syntax-rules (*)
                       ((_ cnt) cnt)
                       ((_ cnt (* item1) item2 ...)
                        (let1 s1 (rec-list item1 cnt)
                          (if (>= s1 limit) limit
                              (sum-items s1 item2 ...))))
                       ((_ cnt item1 item2 ...)
                        (let1 s1 (rec item1 cnt)
                          (if (>= s1 limit) limit
                              (sum-items s1 item2 ...))))))
                    )
      (case/unquote
       (iform-tag iform)
       (($DEFINE) (sum-items (+ cnt 1) ($define-expr iform)))
       (($LREF $GREF $CONST) (+ cnt 1))
       (($LSET)   (sum-items (+ cnt 1) ($lset-expr iform)))
       (($GSET)   (sum-items (+ cnt 1) ($gset-expr iform)))
       (($IF)     (sum-items (+ cnt 1) ($if-test iform)
                             ($if-then iform) ($if-else iform)))
       (($LET)
        (sum-items (+ cnt 1) (* ($let-inits iform)) ($let-body iform)))
       (($RECEIVE)
        (sum-items (+ cnt 1) ($receive-expr iform) ($receive-body iform)))
       (($LAMBDA)
        (sum-items (+ cnt 1) ($lambda-body iform)))
       (($LABEL)
        (sum-items cnt ($label-body iform)))
       (($SEQ)
        (sum-items cnt (* ($seq-body iform))))
       (($CALL)
        (sum-items (+ cnt 1) ($call-proc iform) (* ($call-args iform))))
       (($ASM)
        (sum-items (+ cnt 1) (* ($asm-args iform))))
       (($PROMISE)
        (sum-items (+ cnt 1) ($promise-expr iform)))
       (($CONS $APPEND $MEMV $EQ? $EQV?)
        (sum-items (+ cnt 1) ($*-arg0 iform) ($*-arg1 iform)))
       (($VECTOR $LIST $LIST*)
        (sum-items (+ cnt 1) (* ($*-args iform))))
       (($LIST->VECTOR)
        (sum-items (+ cnt 1) ($*-arg0 iform)))
       (($IT) cnt)
       (else
        (error "[internal error] iform-count-size-upto: unknown iform tag:"
               (iform-tag iform)))
       )))
  (define (rec-list iform-list cnt)
    (cond ((null? iform-list) cnt)
          ((>= cnt limit) limit)
          (else
           (rec-list (cdr iform-list)
                     (rec (car iform-list) cnt)))))
  (rec iform 0))

;; Copy iform.
;;  Lvars that are bound within iform should be copied.  Other lvars
;;  (free in iform, bound outside iform) should be shared and their
;;  refcount should be adjusted.  lv-alist keeps assoc list of
;;  old lvar to copied lvar.

(define (iform-copy iform lv-alist)
  (define label-alist '()) ;; alist of old-label & new-label 
  
  (case/unquote
   (iform-tag iform)
   (($DEFINE)
    ($define ($*-src iform) ($define-flags iform) ($define-id iform)
             (iform-copy ($define-expr iform) lv-alist)))
   (($LREF)
    ($lref (iform-copy-lvar ($lref-lvar iform) lv-alist)))
   (($LSET)
    ($lset ($lset-lvar iform) (iform-copy ($lset-expr iform) lv-alist)))
   (($GREF)
    ($gref ($gref-id iform)))
   (($GSET)
    ($gset ($gset-id iform) (iform-copy ($gset-expr iform) lv-alist)))
   (($CONST)
    ($const ($const-value iform)))
   (($IF)
    ($if ($*-src iform)
         (iform-copy ($if-test iform) lv-alist)
         (iform-copy ($if-then iform) lv-alist)
         (iform-copy ($if-else iform) lv-alist)))
   (($LET)
    (receive (newlvs newalist)
        (iform-copy-zip-lvs ($let-lvars iform) lv-alist)
      ($let ($*-src iform) ($let-type iform)
            newlvs
            (map (cute iform-copy <> (case ($let-type iform)
                                       ((let) lv-alist)
                                       ((rec) newalist)))
                 ($let-inits iform))
            (iform-copy ($let-body iform) newalist))))
   (($RECEIVE)
    (receive (newlvs newalist)
        (iform-copy-zip-lvs ($receive-lvars iform) lv-alist)
      ($receive ($*-src iform)
                ($receive-reqargs iform) ($receive-optarg iform)
                newlvs (iform-copy ($receive-expr iform) lv-alist)
                (iform-copy ($receive-body iform) newalist))))
   (($LAMBDA)
    (receive (newlvs newalist)
        (iform-copy-zip-lvs ($lambda-lvars iform) lv-alist)
      ($lambda ($*-src iform) ($lambda-name iform)
               ($lambda-reqargs iform) ($lambda-optarg iform)
               newlvs
               (iform-copy ($lambda-body iform) newalist)
               ($lambda-flag iform))))
   (($LABEL)
    (cond ((assq iform label-alist) => (lambda (p) (cdr p)))
          (else
           (let1 newnode
               ($label ($label-src iform) ($label-label iform) #f)
             (push! label-alist (cons iform newnode))
             ($label-body-set! newnode
                               (iform-copy ($label-body iform) label-alist))
             newnode))))
   (($SEQ)
    ($seq (map (cut iform-copy <> lv-alist) ($seq-body iform))))
   (($CALL)
    ($call ($*-src iform)
           (iform-copy ($call-proc iform) lv-alist)
           (map (cut iform-copy <> lv-alist) ($call-args iform))
           #f))
   (($ASM)
    ($asm ($*-src iform) ($asm-insn iform)
          (map (cut iform-copy <> lv-alist) ($asm-args iform))))
   (($PROMISE)
    ($promise ($*-src iform) (iform-copy ($promise-expr iform) lv-alist)))
   (($CONS)
    ($cons ($*-src iform)
           (iform-copy ($*-arg0 iform) lv-alist)
           (iform-copy ($*-arg1 iform) lv-alist)))
   (($APPEND)
    ($append ($*-src iform)
             (iform-copy ($*-arg0 iform) lv-alist)
             (iform-copy ($*-arg1 iform) lv-alist)))
   (($VECTOR)
    ($vector ($*-src iform)
             (map (cut iform-copy <> lv-alist) ($*-args iform))))
   (($LIST->VECTOR)
    ($list->vector ($*-src iform) (iform-copy ($*-arg0 iform) lv-alist)))
   (($LIST)
    ($list ($*-src iform)
           (map (cut iform-copy <> lv-alist) ($*-args iform))))
   (($LIST*)
    ($list* ($*-src iform)
            (map (cut iform-copy <> lv-alist) ($*-args iform))))
   (($MEMV)
    ($memv ($*-src iform)
           (iform-copy ($*-arg0 iform) lv-alist)
           (iform-copy ($*-arg1 iform) lv-alist)))
   (($EQ?)
    ($eq? ($*-src iform)
          (iform-copy ($*-arg0 iform) lv-alist)
          (iform-copy ($*-arg1 iform) lv-alist)))
   (($EQV?)
    ($eqv? ($*-src iform)
           (iform-copy ($*-arg0 iform) lv-alist)
           (iform-copy ($*-arg1 iform) lv-alist)))
   (($IT) ($it))
   (else iform)))

(define (iform-copy-zip-lvs orig-lvars lv-alist)
  (let1 new-lvars (map (lambda (lv) (make-lvar (lvar-name lv))) orig-lvars)
    (values new-lvars
            (fold-right acons lv-alist orig-lvars new-lvars))))

(define (iform-copy-lvar lvar lv-alist)
  ;; NB: using extra lambda after => is a kludge for the current optimizer
  ;; to work better.  Should be gone later.
  (cond ((assoc lvar lv-alist) => (lambda (p) (cdr p)))
        (else lvar)))

;; An aux proc called during pass 2 to determine free variables of
;; a closure.   Bounds is a list of lvars that are bound in this scope
;; (thus can't be free).
;(define (iform-free-lvars iform bounds)
;  (define label-alist '()) ;; alist of old-label & new-label 
  
;  (case/unquote
;   (iform-tag iform)
;   (($DEFINE)
;    ($define ($*-src iform) ($define-flags iform) ($define-id iform)
;             (iform-copy ($define-expr iform) lv-alist)))
;   (($LREF)
;    ($lref (iform-copy-lvar ($lref-lvar iform) lv-alist)))
;   (($LSET)
;    ($lset ($lset-lvar iform) (iform-copy ($lset-expr iform) lv-alist)))
;   (($GREF)
;    ($gref ($gref-id iform)))
;   (($GSET)
;    ($gset ($gset-id iform) (iform-copy ($gset-expr iform) lv-alist)))
;   (($CONST)
;    ($const ($const-value iform)))
;   (($IF)
;    ($if ($*-src iform)
;         (iform-copy ($if-test iform) lv-alist)
;         (iform-copy ($if-then iform) lv-alist)
;         (iform-copy ($if-else iform) lv-alist)))
;   (($LET)
;    (receive (newlvs newalist)
;        (iform-copy-zip-lvs ($let-lvars iform) lv-alist)
;      ($let ($*-src iform) ($let-type iform)
;            newlvs
;            (map (cute iform-copy <> (case ($let-type iform)
;                                       ((let) lv-alist)
;                                       ((rec) newalist)))
;                 ($let-inits iform))
;            (iform-copy ($let-body iform) newalist))))
;   (($RECEIVE)
;    (receive (newlvs newalist)
;        (iform-copy-zip-lvs ($receive-lvars iform) lv-alist)
;      ($receive ($*-src iform)
;                ($receive-reqargs iform) ($receive-optarg iform)
;                newlvs (iform-copy ($receive-expr iform) lv-alist)
;                (iform-copy ($receive-body iform) newalist))))
;   (($LAMBDA)
;    (receive (newlvs newalist)
;        (iform-copy-zip-lvs ($lambda-lvars iform) lv-alist)
;      ($lambda ($*-src iform) ($lambda-name iform)
;               ($lambda-reqargs iform) ($lambda-optarg iform)
;               newlvs
;               (iform-copy ($lambda-body iform) newalist)
;               ($lambda-flag iform))))
;   (($LABEL)
;    (cond ((assq iform label-alist) => (lambda (p) (cdr p)))
;          (else
;           (let1 newnode
;               ($label ($label-src iform) ($label-label iform) #f)
;             (push! label-alist (cons iform newnode))
;             ($label-body-set! newnode
;                               (iform-copy ($label-body iform) label-alist))
;             newnode))))
;   (($SEQ)
;    ($seq (map (cut iform-copy <> lv-alist) ($seq-body iform))))
;   (($CALL)
;    ($call ($*-src iform)
;           (iform-copy ($call-proc iform) lv-alist)
;           (map (cut iform-copy <> lv-alist) ($call-args iform))
;           #f))
;   (($ASM)
;    ($asm ($*-src iform) ($asm-insn iform)
;          (map (cut iform-copy <> lv-alist) ($asm-args iform))))
;   (($PROMISE)
;    ($promise ($*-src iform) (iform-copy ($promise-expr iform) lv-alist)))
;   (($CONS)
;    ($cons ($*-src iform)
;           (iform-copy ($*-arg0 iform) lv-alist)
;           (iform-copy ($*-arg1 iform) lv-alist)))
;   (($APPEND)
;    ($append ($*-src iform)
;             (iform-copy ($*-arg0 iform) lv-alist)
;             (iform-copy ($*-arg1 iform) lv-alist)))
;   (($VECTOR)
;    ($vector ($*-src iform)
;             (map (cut iform-copy <> lv-alist) ($*-args iform))))
;   (($LIST->VECTOR)
;    ($list->vector ($*-src iform) (iform-copy ($*-arg0 iform) lv-alist)))
;   (($LIST)
;    ($list ($*-src iform)
;           (map (cut iform-copy <> lv-alist) ($*-args iform))))
;   (($LIST*)
;    ($list* ($*-src iform)
;            (map (cut iform-copy <> lv-alist) ($*-args iform))))
;   (($MEMV)
;    ($memv ($*-src iform)
;           (iform-copy ($*-arg0 iform) lv-alist)
;           (iform-copy ($*-arg1 iform) lv-alist)))
;   (($EQ?)
;    ($eq? ($*-src iform)
;          (iform-copy ($*-arg0 iform) lv-alist)
;          (iform-copy ($*-arg1 iform) lv-alist)))
;   (($EQV?)
;    ($eqv? ($*-src iform)
;           (iform-copy ($*-arg0 iform) lv-alist)
;           (iform-copy ($*-arg1 iform) lv-alist)))
;   (($IT) ($it))
;   (else iform)))
  

;;============================================================
;; Entry point
;;

;; compile:: Sexpr, Module -> CompiledCode
(define (compile program . opts)
  (let1 mod (get-optional opts #f)
    (if mod
      (let1 origmod (vm-current-module)
        (dynamic-wind
            (lambda () (vm-set-current-module mod))
            (lambda () (compile-int program '%toplevel (make-bottom-cenv) 0 0))
            (lambda () (vm-set-current-module origmod))))
      (compile-int program '%toplevel (make-bottom-cenv) 0 0))))

(define (compile-int program name cenv reqargs optarg)
  (with-error-handler
      ;; TODO: check if e is an expected error (such as syntax error) or
      ;; an unexpected error (compiler bug).
      (lambda (e)
        (let1 srcinfo (and (pair? program)
                           (pair-attribute-get program 'source-info #f))
          (if srcinfo
            (errorf "Compile Error: ~a\n~s:~d:~,,,,40:s\n"
                    (slot-ref e 'message) (car srcinfo) (cadr srcinfo) program)
            (errorf "Compile Error: ~a\n" (slot-ref e 'message)))))
    (lambda ()
      (let1 p1 (pass1 program cenv)
        (pass3 (pass2 p1) '() reqargs optarg name #f #f)))))

;; Returns a compiled toplevel closure.  This is a shortcut of
;; evaluating lambda expression---it skips extra code segment
;; that only has CLOSURE instruction.
(define (compile-toplevel-lambda oform name formals body module)
  (let* ((cenv (make-cenv module '() name))
         (iform (pass2 (pass1/lambda oform formals body cenv #f))))
    (make-toplevel-closure
     (pass3 ($lambda-body iform)
            (list ($lambda-lvars iform))
            ($lambda-reqargs iform)
            ($lambda-optarg iform)
            ($lambda-name iform) #f #f))))
  
;; For testing
(define (compile-p1 program)
  (pp-iform (pass1 program (make-bottom-cenv))))

(define (compile-p2 program)
  (pp-iform (pass2 (pass1 program (make-bottom-cenv)))))

(define (compile-p3 program)
  (vm-dump-code (pass3 (pass2 (pass1 program (make-bottom-cenv))) '() 0 0
                       '%toplevel #f #f)))

;;===============================================================
;; Pass 1
;;
;;   Converts S-expr to IForm.  Macros are expanded.  Variable references
;;   are resolved and converted to either $lref or $gref.  The constant
;;   variable references (defined by define-constant) are converted to
;;   its values at this stage.

;; pass1 :: Sexpr, Cenv -> IForm
(define (pass1 program cenv)
  (cond
    ((pair? program)  ;; (op . args)
     (if (variable? (car program))
       (let1 head (cenv-lookup cenv (car program) SYNTAX)
         (cond
          ((lvar? head)
           (pass1/call program ($lref head) (cdr program) cenv))
          ((is-a? head <macro>)
           (pass1 (call-macro-expander head program (cenv-frames cenv)) cenv))
          ((identifier? head)
           (pass1/global-call head program cenv))
          (else
           (error "[internal] unknown resolution of head:" head))))
       (pass1/call program (pass1 (car program) (cenv-sans-name cenv))
                   (cdr program) cenv)))
    ((variable? program)
     (pass1/variable program cenv))
    (else
     ($const program))))

;; handle variable reference
(define (pass1/variable var cenv)
  (let ((r (cenv-lookup cenv var LEXICAL)))
    (cond ((lvar? r) ($lref r))
          ((variable? r)
           (receive (mod name)
               (if (identifier? r)
                 (values (slot-ref r 'module) (slot-ref r 'name))
                 (values (cenv-module cenv) r))
             (or (and-let* ((gloc (find-binding mod name #f))
                            ( (gloc-const? gloc) )
                            ( (not (vm-compiler-flag-is-set?
                                    SCM_COMPILE_NOINLINE_CONSTS)) ))
                   ($const (gloc-ref gloc)))
                 ($gref (ensure-identifier r cenv)))))
          (else
           (error "[internal] pass1/variable got weird object:" var)))))

;; handle global procedure call (when we know the operator is a global
;; variable reference; in this case, we may have macro expansion or
;; inline expansion).
(define (pass1/global-call id program cenv)
  (let1 gloc (find-binding (slot-ref id 'module)
                           (slot-ref id 'name)
                           #f)
    (if (not gloc)
      (pass1/call program ($gref id) (cdr program) cenv)
      (let1 gval (gloc-ref gloc)
        (cond
         ((is-a? gval <macro>)
          (pass1 (call-macro-expander gval program (cenv-frames cenv)) cenv))
         ((is-a? gval <syntax>)
          (call-syntax-compiler gval program cenv))
         ((and (not (vm-compiler-flag-is-set? SCM_COMPILE_NOINLINE_GLOBALS))
               (procedure? gval)
               (%procedure-inliner gval))
          (pass1/expand-inliner id gval program cenv))
         (else
          (pass1/call program ($gref id) (cdr program) cenv)))))))

;; handle procedure call
;; KLUDGE: the body should be this simple:
;;
;;   ($call program proc (map (cute pass1 <> (cenv-sans-name cenv)) args))
;;
;;   However, we want to make it FAST, so we manually unfold pass1
;;   application to avoid closure creation in typical cases.  Should be
;;   cleaned up once our compiler does clever closure optimization.
;; 
(define (pass1/call program proc args cenv)
  (case (length args)
    ((0) ($call program proc () #f))
    ((1) ($call program proc
                (list (pass1 (car args) (cenv-sans-name cenv))) #f))
    ((2) (let1 cenv (cenv-sans-name cenv)
           ($call program proc (list (pass1 (car args) cenv)
                                     (pass1 (cadr args) cenv)) #f)))
    ((3) (let1 cenv (cenv-sans-name cenv)
           ($call program proc (list (pass1 (car args) cenv)
                                     (pass1 (cadr args) cenv)
                                     (pass1 (caddr args) cenv)) #f)))
    (else
     ($call program proc
            (map (cute pass1 <> (cenv-sans-name cenv)) args) #f))))

;; Compiling body with internal definitions.
;;
;; First we scan internal defines.  We need to expand macros at this stage,
;; since the macro may produce more internal defines.  Note that the
;; previous internal definition in the same body may shadow the macro
;; binding, so we need to check idef_vars for that.
;;
;; Actually, this part touches the hole of R5RS---we can't determine
;; the scope of the identifiers of the body until we find the boundary
;; of internal define's, but in order to find all internal defines
;; we have to expand the macro and we need to detemine the scope
;; of the macro keyword.  Search "macro internal define" in
;; comp.lang.scheme for the details.
;;
;; I use the model that appears the same as Chez, which adopts
;; let*-like semantics for the purpose of determining macro binding
;; during expansion.
(define (pass1/body exprs intdefs cenv)
  (cond
   ((null? exprs) ($const-undef))
   ((pair? (car exprs))
    (let ((op   (caar exprs))
          (args (cdar exprs))
          (rest (cdr exprs)))
      (if (or (not (variable? op)) (assq op intdefs))
        ;; This can't be an internal define.
        (pass1/body-wrap-intdefs intdefs exprs cenv)
        (let1 var (cenv-lookup cenv op SYNTAX)
          (cond
           ((lvar? var) (pass1/body-wrap-intdefs intdefs exprs cenv))
           ((is-a? var <macro>)
            (pass1/body
             (cons (call-macro-expander var (car exprs) (cenv-frames cenv))
                   rest)
             intdefs cenv))
           ((identifier? var)
            (cond
             ((global-eq? var 'define cenv)
              (when (null? args)
                (error "malformed internal define:" (car expr)))
              (pass1/body-handle-intdef args rest intdefs cenv))
             ((global-eq? var 'begin cenv)
              ;; intersperse the body of begin
              (pass1/body (append args rest) intdefs cenv))
             (else
              (or (and-let* ((gloc (find-binding (slot-ref var 'module)
                                                 (slot-ref var 'name)
                                                 #f))
                             (gval (gloc-ref gloc))
                             ( (is-a? gval <macro>) ))
                    (pass1/body
                     (cons (call-macro-expander gval (car exprs) (cenv-frames cenv))
                           rest)
                     intdefs cenv))
                  (pass1/body-wrap-intdefs intdefs exprs cenv)))))
           (else
            (error "[internal] pass1/body" var)))))))
    (else
     (pass1/body-wrap-intdefs intdefs exprs cenv))))

;; an internal define is found.  def is cdr of internal define.
;; we know def isn't null.
(define (pass1/body-handle-intdef def exprs intdefs cenv)
  (cond
   ((pair? (car def))
    (let ((name (caar def))
          (args (cdar def))
          (body (cdr def)))
      (pass1/body exprs
                  (cons (list name `(,lambda. ,args ,@body)) intdefs)
                  cenv)))
   ((and (pair? (cdr def)) (null? (cddr def)))
    (pass1/body exprs (cons def intdefs) cenv))
   (else
    (error "malformed internal define:" `(define . ,def)))))

;; Finishing internal definitions.  If we have internal defs, we wrap
;; the rest by letrec.
(define (pass1/body-wrap-intdefs intdefs exprs cenv)
  (cond
   ((not (null? intdefs))
    (pass1 `(,(global-id 'letrec) ,intdefs ,@exprs) cenv))
   ((null? exprs)
    ($seq '()))
   ((null? (cdr exprs))
    (pass1 (car exprs) cenv))
   (else
    (let1 stmtenv (cenv-sans-name cenv)
      ($seq (let loop ((exprs exprs)
                       (r '()))
              (if (null? (cdr exprs))
                (reverse! (cons (pass1 (car exprs) cenv) r))
                (loop (cdr exprs)
                      (cons (pass1 (car exprs) stmtenv) r)))))))))

;; Expand inlinable procedure.  Inliner may be...
;;   - An integer.  This must be the VM instruction number.
;;     (It is useful to initialize the inliner statically in .stub file).
;;   - A vector.  This must be an intermediate form.  It is set if
;;     the procedure is defined by define-inline.
;;   - A procedure.   It is called like a macro expander.
;;     It may return #<undef> to cancel inlining.
(define (pass1/expand-inliner name proc program cenv)
  ;; TODO: for inline asm, check validity of opcode.
  (let1 inliner (%procedure-inliner proc)
    (cond
     ((integer? inliner)
      (let ((nargs (length (cdr program)))
            (opt?  (slot-ref proc 'optional)))
        (unless (argcount-ok? (cdr program) (slot-ref proc 'required) opt?)
          (errorf "wrong number of arguments: ~a requires ~a, but got ~a"
                  (variable-name name) (slot-ref proc 'required) nargs))
        ($asm program (if opt? `(,inliner ,nargs) `(,inliner))
              (map (cut pass1 <> cenv) (cdr program)))))
     ((vector? inliner)
      (expand-inlined-procedure program
                                (unpack-iform inliner)
                                (map (cut pass1 <> cenv) (cdr program))))
     (else
      (let1 form (inliner program cenv)
        (if (undefined? form)
          (pass1/call program ($gref name) (cdr program) cenv)
          form))))))

;;--------------------------------------------------------------
;; Pass1 utilities
;;

;; get symbol or id, and returns identiier.
(define (ensure-identifier sym-or-id cenv)
  (if (identifier? sym-or-id)
    sym-or-id
    (make-identifier sym-or-id '() (cenv-module cenv))))

;; Returns <list of args>, <# of reqargs>, <has optarg?>
(define (parse-lambda-args formals)
  (let loop ((formals formals) (args '()))
    (cond ((null? formals) (values (reverse args) (length args) 0))
          ((pair? formals) (loop (cdr formals) (cons (car formals) args)))
          (else (values (reverse (cons formals args)) (length args) 1)))))

;; Does the given argument list satisfy procedure's reqargs/optarg?
(define (argcount-ok? args reqargs optarg?)
  (let1 nargs (length args)
    (or (and (not optarg?) (= nargs reqargs))
        (and optarg? (>= nargs reqargs)))))

;; signal an error if the form is not on the toplevel
(define (check-toplevel form cenv)
  (unless (cenv-toplevel? cenv)
    (error "syntax-error: the form can appear only in the toplevel:" form)))

;; returns a module specified by THING.
(define (ensure-module thing name create?)
  (let1 mod 
      (cond ((symbol? thing) (find-module thing))
            ((identifier? thing) (find-module (slot-ref thing 'name)))
            ((module? thing) thing)
            (else
             (errorf "~a requires a module name or a module, but got: ~s"
                     name thing)))
    (or mod
        (if create?
          (make-module (if (identifier? thing) (slot-ref thing 'name) thing))
          (errorf "~a: no such module: ~s" name thing)))))

;; IFORM must be a $LAMBDA node.  This expands the application of IFORM
;; on IARGS (list of IForm) into a mere $LET node.
;; The nodes within IFORM will be reused in the resulting $LET structure,
;; so be careful not to share substructures of IFORM accidentally.
(define (expand-inlined-procedure src iform iargs)
  (let ((lvars ($lambda-lvars iform))
        (args  (adjust-arglist ($lambda-reqargs iform) ($lambda-optarg iform)
                               iargs ($lambda-name iform))))
    (for-each (lambda (lv a) (lvar-initval-set! lv a)) lvars args)
    ($let src 'let lvars args ($lambda-body iform))))

;; Adjust argument list according to reqargs and optarg count.
;; Used in procedure inlining and local call optimization.
(define (adjust-arglist reqargs optarg iargs name)
  (unless (argcount-ok? iargs reqargs (> optarg 0))
    (errorf "wrong number of arguments: ~a requires ~a, but got ~a"
            name reqargs (length iargs)))
  (if (zero? optarg)
    iargs
    (receive (reqs opts) (split-at iargs reqargs)
      (append! reqs (list ($list #f opts))))))
    
;;----------------------------------------------------------------
;; Pass1 syntaxes
;;

(define-macro (define-pass1-syntax formals module . body)
  (let ((mod (case module
               ((:null)   'null)
               ((:gauche) 'gauche)))
        ;; a trick to assign comprehensive name to body:
        (name (string->symbol #`"syntax/,(car formals)")))
    `(let ((,name (lambda ,(cdr formals) ,@body)))
       (%insert-binding (find-module ',mod) ',(car formals)
                        (make-syntax ',(car formals) ,name)))))

(define (global-id id)
  (make-identifier id '() (find-module 'gauche)))

(define lambda. (global-id 'lambda))
(define setter. (global-id 'setter))

;; Definitions ........................................

(define (pass1/define form oform flags module cenv)
  (check-toplevel oform cenv)
  (match form
    ((_ (name . args) body ...)
     (pass1/define `(define ,name
                      (,lambda. ,args ,@body))
                   oform flags module cenv))
    ((_ name expr)
     (unless (variable? name)
       (error "syntax-error:" origform))
     (let1 cenv (cenv-add-name cenv (variable-name name))
       ($define oform flags
                (make-identifier (unwrap-syntax name) '() module)
                (pass1 expr cenv))))
    (else (error "syntax-error:" oform))))

(define-pass1-syntax (define form cenv) :null
  (pass1/define form form '() (cenv-module cenv) cenv))

(define-pass1-syntax (define-constant form cenv) :gauche
  (pass1/define form form '(const) (cenv-module cenv) cenv))

(define-pass1-syntax (define-in-module form cenv) :gauche
  (match form
    ((_ module . rest)
     (pass1/define `(_ . ,rest) form '()
                   (ensure-module module 'define-in-module #f)
                   cenv))
    (else (error "syntax-error: malformed define-in-module:" form))))

(define (pass1/define-macro form oform module cenv)
  (check-toplevel oform cenv)
  (match form
    ((_ (name . formals) body ...)
     (let1 trans
         (make-macro-transformer name
                                 (compile-toplevel-lambda form name formals
                                                          body module))
       (%insert-binding module name trans)
       ($const-undef)))
    ((_ name expr)
     (unless (variable? name)
       (error "syntax-error:" origform))
     ;; TODO: macro autoload
     (let1 trans (make-macro-transformer name (eval expr module))
       (%insert-binding module name trans)
       ($const-undef)))
    (else (error "syntax-error:" oform))))

(define-pass1-syntax (define-macro form cenv) :gauche
  (check-toplevel form cenv)
  (pass1/define-macro form form (cenv-module cenv) cenv))


(define-pass1-syntax (define-syntax form cenv) :null
  (check-toplevel form cenv)
  ;; Temporary: we use the old compiler's syntax-rules implementation
  ;; for the time being.
  (match form
    ((_ name ('syntax-rules (literal ...) rule ...))
     (let1 transformer
         (compile-syntax-rules name literal rule (cenv-frames cenv))
       (%insert-binding (cenv-module cenv) name transformer)
       ($const-undef)))
    (else
     (error "syntax-error: malformed define-syntax:" form))))

;; Inlinable procedure.
;;   Inlinable procedure has both properties of a macro and a procedure.
;;   It is a bit tricky since the inliner information has to exist
;;   both in compile time and execution time.
(define-pass1-syntax (define-inline form cenv) :gauche
  (check-toplevel form cenv)
  (match form
    ((_ (name . args) . body)
     (pass1/define-inline form name args body cenv))
    ((_ name (op args . body))
     (if (global-eq? op 'lambda cenv)
       (pass1/define-inline form name args body cenv)
       (pass1/define `(_ ,name (,op ,args ,@body)) form
                     '() (cenv-module cenv) cenv)))
    ((_ name expr)
     (pass1/define `(_ ,name ,expr) form '(const) (cenv-module cenv) cenv))
    (else
     (error "syntax-error: malformed define-inline:" form))))

(define (pass1/define-inline form name formals body cenv)
  (let ((p1 (pass1/lambda form formals body
                          (cenv-add-name cenv (variable-name name)) 'inlined))
        (module  (cenv-module cenv))
        (dummy-proc (lambda _ (undefined))))
    ;; record inliner function for compiler
    (%insert-binding module name dummy-proc)
    (set! (%procedure-inliner dummy-proc)
          (pass1/inliner-procedure (pack-iform p1)))
    ;; for execution time, the required information is recorded in
    ;; the compiled-code.
    ($define form '()
             (make-identifier (unwrap-syntax name) '() module)
             p1)
    ))

(define (pass1/inliner-procedure ivec)
  (lambda (form cenv)
    (expand-inlined-procedure form (unpack-iform ivec)
                              (map (cut pass1 <> cenv) (cdr form)))))

;; Macros ...........................................

(define-pass1-syntax (%macroexpand form cenv) :gauche
  (match form
    ((_ expr) ($const (%internal-macro-expand expr (cenv-frames cenv) #f)))
    (else "syntax-error: malformed %macroexpand:" form)))

(define-pass1-syntax (%macroexpand-1 form cenv) :gauche
  (match form
    ((_ expr) ($const (%internal-macro-expand expr (cenv-frames cenv) #t)))
    (else "syntax-error: malformed %macroexpand-1:" form)))

(define-pass1-syntax (let-syntax form cenv) :null
  (match form
    ((_ ((name trans-spec) ...) body ...)
     (let* ((trans (map (lambda (n spec)
                          (match spec
                            (('syntax-rules (lit ...) rule ...)
                             (compile-syntax-rules n lit rule
                                                   (cenv-frames cenv)))
                            (else
                             (error "syntax-error: malformed transformer-spec:"
                                    spec))))
                        name trans-spec))
            (newenv (cenv-extend cenv (map cons name trans) SYNTAX)))
       (pass1/body body '() newenv)))
    (else "syntax-error: malformed let-syntax:" form)))

(define-pass1-syntax (letrec-syntax form cenv) :null
  (match form
    ((_ ((name trans-spec) ...) body ...)
     (let* ((newenv (cenv-extend cenv (map cons name trans-spec) SYNTAX))
            (trans (map (lambda (n spec)
                          (match spec
                            (('syntax-rules (lit ...) rule ...)
                             (compile-syntax-rules n lit rule
                                                   (cenv-frames newenv)))
                            (else
                             (error "syntax-error: malformed transformer-spec:"
                                    spec))))
                        name trans-spec)))
       (for-each set-cdr! (cdar (cenv-frames newenv)) trans)
       (pass1/body body '() newenv)))
    (else "syntax-error: malformed letrec-syntax:" form)))

;; If family ........................................

(define-pass1-syntax (if form cenv) :null
  (match form
    ((_ test then else)
     ($if form (pass1 test (cenv-sans-name cenv))
          (pass1 then cenv) (pass1 else cenv)))
    ((_ test then)
     ($if form (pass1 test (cenv-sans-name cenv))
          (pass1 then cenv) ($const-undef)))
    (else
     (error "syntax-error: malformed if:" form))))

(define-pass1-syntax (and form cenv) :null
  (define (rec exprs)
    (match exprs
      (() `#(,$CONST #t))
      ((expr) (pass1 expr cenv))
      ((expr . more)
       ($if #f (pass1 expr (cenv-sans-name cenv)) (rec more) ($it)))
      (else
       (error "syntax-error: malformed and:" form))))
  (rec (cdr form)))

(define-pass1-syntax (or form cenv) :null
  (define (rec exprs)
    (match exprs
      (() `#(,$CONST #f))
      ((expr) (pass1 expr cenv))
      ((expr . more)
       ($if #f (pass1 expr (cenv-sans-name cenv)) ($it) (rec more)))
      (else
       (error "syntax-error: malformed or:" form))))
  (rec (cdr form)))

(define-pass1-syntax (when form cenv) :gauche
  (match form
    ((_ test body ...)
     (let1 cenv (cenv-sans-name cenv)
       ($if form (pass1 test cenv)
            ($seq (map (cut pass1 <> cenv) body))
            ($const-undef))))
    (else
     (error "syntax-error: malformed when:" form))))

(define-pass1-syntax (unless form cenv) :gauche
  (match form
    ((_ test body ...)
     (let1 cenv (cenv-sans-name cenv)
       ($if form (pass1 test cenv)
            ($const-undef)
            ($seq (map (cut pass1 <> cenv) body)))))
    (else
     (error "syntax-error: malformed unless:" form))))

(define-pass1-syntax (cond form cenv) :null
  (define (process-clauses cls)
    (match cls
      (() ($const-undef))
      ((((? (global-eq?? 'else cenv)) expr ...) . rest)
       (unless (null? rest)
         (error "syntax-error: 'else' clause followed by more clauses:" form))
       ($seq (map (cut pass1 <> cenv) expr)))
      (((test (? (global-eq?? '=> cenv)) proc) . rest)
       (let* ((ttree (pass1 test cenv))
              (tmp (make-lvar 'tmp)))
         (lvar-initval-set! tmp ttree)
         ($let (car cls) 'let
               (list tmp)
               (list ttree)
               ($if (car cls)
                    ($lref tmp)
                    ($call (car cls)
                           (pass1 proc (cenv-sans-name cenv))
                           (list ($lref tmp))
                           #f)
                    (process-clauses rest)))))
      (((test) . rest)
       ($if (car cls) (pass1 test (cenv-sans-name cenv))
            ($it) (process-clauses rest)))
      (((test expr ...) . rest)
       ($if (car cls) (pass1 test (cenv-sans-name cenv))
            ($seq (map (cut pass1 <> cenv) expr))
            (process-clauses rest)))
      (else
       (error "syntax-error: bad clause in cond:" form))))
  (match form
    ((_)
     (error "syntax-error: at least one clause is required for cond:" form))
    ((_ clause ...)
     (process-clauses clause))
    (else
     (error "syntax-error: malformed cond:" form))))

(define-pass1-syntax (case form cenv) :null
  (define (process-clauses tmpvar cls)
    (match cls
      (() ($const-undef))
      ((('else expr ...) . rest) ;; NB: use global-id=?
       (unless (null? rest)
         (error "syntax-error: 'else' clause followed by more clauses:" form))
       ($seq (map (cut pass1 <> cenv) expr)))
      ((((elt ...) expr ...) . rest)
       (let* ((nelts (length elt))
              (elts (map unwrap-syntax elt)))
         (unless (> nelts 0)
           (error "syntax-error: bad clause in case:" form))
         ($if (car cls)
              (if (> nelts 1)
                ($memv #f ($lref tmpvar) ($const elts))
                (if (symbol? (car elts))
                  ($eq? #f  ($lref tmpvar) ($const (car elts)))
                  ($eqv? #f ($lref tmpvar) ($const (car elts)))))
              ($seq (map (cut pass1 <> cenv) expr))
              (process-clauses tmpvar rest))))
      (else
       (error "syntax-error: bad clause in case:" form))))
  
  (match form
    ((_)
     (error "syntax-error: at least one clause is required for case:" form))
    ((_ expr clause ...)
     (let* ((etree (pass1 expr cenv))
            (tmp (make-lvar 'tmp)))
       (lvar-initval-set! tmp etree)
       ($let form 'let
             (list tmp)
             (list etree)
             (process-clauses tmp clause))))
    (else
     (error "syntax-error: malformed case:" form))))

(define-pass1-syntax (and-let* form cenv) :gauche
  (define (process-binds binds body cenv)
    (match binds
      (() (pass1/body body '() cenv))
      (((exp) . more)
       ($if form (pass1 exp (cenv-sans-name cenv))
            (process-binds more body cenv)
            ($it)))
      ((((? variable? var) init) . more)
       (let* ((lvar (make-lvar var))
              (newenv (cenv-extend cenv `((,var . ,lvar)) LEXICAL))
              (itree (pass1 init (cenv-add-name cenv (variable-name lvar)))))
         (lvar-initval-set! lvar itree)
         ($let form 'let
               (list lvar)
               (list itree)
               ($if form ($lref lvar)
                    (process-binds more body newenv)
                    ($it)))))
      (else (error "syntax-error: malformed and-let*:" form))))
  (match form
    ((_ binds . body) (process-binds binds body cenv))
    (else (error "syntax-error: malformed and-let*:" form))))

;; Quote and quasiquote ................................

(define (pass1/quote obj)
  ($const (unwrap-syntax obj)))

(define-pass1-syntax (quote form cenv) :null
  (match form
    ((_ obj) (pass1/quote obj))
    (else (error "syntax-error: malformed quote:" form))))

(define-pass1-syntax (quasiquote form cenv) :null
  ;; We want to avoid unnecessary allocation as much as possible.
  ;; Current code generates constants not only the obvious constant
  ;; case, e.g. `(a b c), but also folds constant variable references,
  ;; e.g. (define-constant x 3) then `(,x) generate a constant list '(3).
  ;; This extends as far as the constant folding goes, so `(,(+ x 1)) also
  ;; becomes '(4).

  ;; The internal functions returns two values, of which the first value
  ;; indicates whether the subtree is constant or not.   The second value
  ;; is a constant object (if the subtree is constant), or an IForm (if
  ;; the subtree is non-constant).

  (define (wrap const? tree)
    (if const? ($const tree) tree))

  (define (quasi obj level)
    (match obj
      (('quasiquote x)
       (receive (c? r) (quasi x (+ level 1))
         (if c?
           (values #t (list 'quasiquote r))
           (values #f ($list obj (list ($const 'quasiquote) r))))))
      (('unquote x)
       (if (zero? level)
         (let1 r (pass1 x cenv)
           (if (has-tag? r $CONST)
             (values #t ($const-value r))
             (values #f r)))
         (receive (xc? xx) (quasi x (- level 1))
           (if xc?
             (values #t (list 'unquote xx))
             (values #f ($list obj (list ($const 'unquote) xx)))))))
      ((x 'unquote-splicing y)            ;; `(x . ,@y)
       (if (zero? level)
         (error "unquote-splicing appeared in invalid context:" obj)
         (receive (xc? xx) (quasi x level)
           (receive (yc? yy) (quasi y level)
             (if (and xc? yc?)
               (values #t (list xx 'unquote-splicing yy))
               (values #f ($list obj (list xx ($const 'unquote-splicing) yy))))))))
      ((('unquote-splicing x))            ;; `(,@x)
       (if (zero? level)
         (let1 r (pass1 x cenv)
           (if (has-tag? r $CONST)
             (values #t ($const-value r))
             (values #f r)))
         (receive (xc? xx) (quasi x (- level 1))
           (if xc?
             (values #t (list (list 'unquote-splicing xx)))
             (values #f ($list obj
                               (list ($list (car obj)
                                            (list ($const 'unquote-splicing)
                                                  xx)))))))))
      ((('unquote-splicing x) . y)        ;; `(,@x . rest)
       (receive (yc? yy) (quasi y level)
         (if (zero? level)
           (let1 r (pass1 x cenv)
             (if (and yc? (has-tag? r $CONST))
               (values #t (append ($const-value r) yy))
               (values #f ($append obj r (wrap yc? yy)))))
           (receive (xc? xx) (quasi x (- level 1))
             (if (and xc? yc?)
               (values #t (cons (list 'unquote-splicing xx) yy))
               (values #f ($cons obj
                                 ($list (car obj)
                                        (list ($const 'unquote-splicing)
                                              (wrap xc? xx)))
                                 (wrap yc? yy))))))))
      ((x 'unquote y)                     ;; `(x . ,y)
       (receive (xc? xx) (quasi x level)
         (if (zero? level)
           (let1 r (pass1 y cenv)
             (if (and xc? (has-tag? r $CONST))
               (values #t (cons xx ($const-value r)))
               (values #f ($cons obj (wrap xc? xx) r))))
           (receive (yc? yy) (quasi y level)
             (if (and xc? yc?)
               (values #t (list xx 'unquote yy))
               (values #f ($list obj (list (wrap xc? xx)
                                           ($const 'unquote)
                                           (wrap yc? yy)))))))))
      ((x . y)                            ;; general case of pair
       (receive (xc? xx) (quasi x level)
         (receive (yc? yy) (quasi y level)
           (if (and xc? yc?)
             (values #t (cons xx yy))
             (values #f ($cons obj (wrap xc? xx) (wrap yc? yy)))))))
      ((? vector?) (quasi-vector obj level))
      ((? identifier?)
       (values #t (slot-ref obj 'name))) ;; unwrap syntax
      (else (values #t obj))))

  (define (quasi-vector obj level)
    (if (vector-has-splicing? obj)
      (receive (c? r) (quasi (vector->list obj) level)
        (values #f ($list->vector obj (wrap c? r))))
      (let* ((need-construct? #f)
             (elts (map (lambda (elt)
                          (receive (c? tree) (quasi elt level)
                            (if c?
                              ($const tree)
                              (begin
                                (set! need-construct? #t)
                                tree))))
                        (vector->list obj))))
        (if need-construct?
          (values #f ($vector obj elts))
          (values #t (list->vector (map (lambda (e) ($const-value e)) elts))))
        )))

  (define (vector-has-splicing? obj)
    (let loop ((i 0))
      (cond ((= i (vector-length obj)) #f)
            ((and (pair? (vector-ref obj i))
                  (eq? (car (vector-ref obj i)) 'unquote-splicing))
             #t)
            (else (loop (+ i 1))))))
  
  (match form
    ((_ obj)
     (receive (c? r) (quasi obj 0)
       (wrap c? r)))
    (else (error "syntax-error: malformed quasiquote:" form)))
  )

(define-pass1-syntax (unquote form cenv) :null
  (error "unquote appeared outside quasiquote:" form))

(define-pass1-syntax (unquote-splicing form cenv) :null
  (error "unquote-splicing appeared outside quasiquote:" form))

;; Lambda family (binding constructs) ...................

(define-pass1-syntax (lambda form cenv) :null
  (match form
    ((_ formals . body)
     (pass1/lambda form formals body cenv #f))
    (else
     (error "syntax-error: malformed lambda:" form))))

(define (pass1/lambda form formals body cenv flag)
  (receive (args reqargs optarg) (parse-lambda-args formals)
    (let* ((lvars (map make-lvar args))
           (intform ($lambda form (cenv-exp-name cenv)
                             reqargs optarg lvars #f flag))
           (newenv (cenv-extend/proc cenv (map cons args lvars)
                                     LEXICAL intform)))
      (vector-set! intform 6 (pass1/body body '() newenv))
      intform)))

(define-pass1-syntax (receive form cenv) :gauche
  (match form
    ((_ formals expr body ...)
     (receive (args reqargs optarg) (parse-lambda-args formals)
       (let* ((lvars (map make-lvar args))
              (newenv (cenv-extend cenv (map cons args lvars) LEXICAL)))
         ($receive form reqargs optarg lvars (pass1 expr cenv)
                   (pass1/body body '() newenv)))))
    (else
     (error "syntax-error: malformed receive:" form))))

(define-pass1-syntax (let form cenv) :null
  (match form
    ((_ () body ...)
     (pass1/body body '() cenv))
    ((_ ((var expr) ...) body ...)
     (let* ((lvars (map make-lvar var))
            (newenv (cenv-extend cenv (map cons var lvars) LEXICAL)))
       ($let form 'let lvars
             (map (lambda (init lvar)
                    (let1 iexpr
                        (pass1 init (cenv-add-name cenv (variable-name lvar)))
                      (lvar-initval-set! lvar iexpr)
                      iexpr))
                  expr lvars)
             (pass1/body body '() newenv))))
    ((_ name ((var expr) ...) body ...)
     (unless (variable? name)
       (error "bad name for named let:" name))
     ;; Named let.  (let name ((var exp) ...) body ...)
     ;;
     ;;  We don't use the textbook expansion here
     ;;    ((letrec ((name (lambda (var ...) body ...))) name) exp ...)
     ;;
     ;;  Instead, we use the following expansion, except that we cheat
     ;;  environment during expanding {exp ...} so that the binding of
     ;;  name doesn't interfere with exp ....
     ;;  
     ;;    (letrec ((name (lambda (var ...) body ...))) (name {exp ...}))
     ;;
     ;;  The reason is that this form can be more easily spotted by
     ;;  our simple-minded closure optimizer in Pass 2.
     (let* ((lvar (make-lvar name))
            (args (map make-lvar var))
            (env1 (cenv-extend cenv `((,name . ,lvar)) LEXICAL))
            (env2 (cenv-extend/name env1 (map cons var args) LEXICAL name))
            (lmda ($lambda form name (length args) 0 args
                           (pass1/body body '() env2) #f)))
       (lvar-initval-set! lvar lmda)
       ($let form 'rec
             (list lvar)
             (list lmda)
             ($call #f ($lref lvar)
                    (map (cute pass1 <> (cenv-sans-name cenv)) expr)
                    #f))))
    (else
     (error "syntax-error: malformed let:" form))))

(define-pass1-syntax (let* form cenv) :null
  (match form
    ((_ ((var expr) ...) body ...)
     (let loop ((vars var) (inits expr) (cenv cenv))
       (if (null? vars)
         (pass1/body body '() cenv)
         (let* ((lv (make-lvar (car vars)))
                (newenv (cenv-extend cenv `((,(car vars) . ,lv)) LEXICAL))
                (iexpr (pass1 (car inits)
                              (cenv-add-name cenv (variable-name lv)))))
           (lvar-initval-set! lv iexpr)
           ($let #f 'let (list lv) (list iexpr)
                 (loop (cdr vars) (cdr inits) newenv))))))
    (else
     (error "syntax-error: malformed let*:" form))))

(define-pass1-syntax (letrec form cenv) :null
  (match form
    ((_ () body ...)
     (pass1/body body '() cenv))
    ((_ ((var expr) ...) body ...)
     (let* ((lvars (map make-lvar var))
            (newenv (cenv-extend cenv (map cons var lvars) LEXICAL))
            )
       ($let form 'rec lvars
             (map (lambda (lv init)
                    (let1 iexpr
                        (pass1 init (cenv-add-name newenv (lvar-name lv)))
                      (lvar-initval-set! lv iexpr)
                      iexpr))
                  lvars expr)
             (pass1/body body '() newenv))))
    (else
     (error "syntax-error: malformed letrec:" form))))

(define-pass1-syntax (do form cenv) :null
  (match form
    ((_ ((var init . update) ...) (test expr ...) body ...)
     (let* ((tmp  (make-lvar 'do-proc))
            (args (map make-lvar var))
            (newenv (cenv-extend/proc cenv (map cons var args) LEXICAL 'do-proc))
            (clo ($lambda
                  form 'do-body (length var) 0 args
                  ($if #f
                       (pass1 test newenv)
                       (if (null? expr)
                         ($it)
                         ($seq (map (cut pass1 <> newenv) expr)))
                       ($seq
                        (list
                         (pass1/body body '() newenv)
                         ($call form
                                ($lref tmp)
                                (map (lambda (upd arg)
                                        (match upd
                                         (() ($lref arg))
                                         ((expr)
                                          (pass1 expr newenv))
                                         (else
                                          (error "bad update expr in do:"
                                                 form))))
                                     update args)
                                #f))))
                  #f))
            )
       (lvar-initval-set! tmp clo)
       ($let form 'rec
             (list tmp)
             (list clo)
             ($call form
                    ($lref tmp)
                    (map (cute pass1 <> (cenv-sans-name cenv)) init)
                    #f))))
    (else
     (error "syntax-error: malformed do:" form))))

;; Set! ......................................................

(define-pass1-syntax (set! form cenv) :null
  (match form
    ((_ (op . args) expr)
     ($call form
            ($call #f
                   ($gref setter.)
                   (list (pass1 op cenv)) #f)
            (let1 cenv (cenv-sans-name cenv)
              (append (map (cut pass1 <> cenv) args)
                      (list (pass1 expr cenv))))
            #f))
    ((_ name expr)
     (unless (variable? name)
       (error "syntax-error: malformed set!:" form))
     (let ((var (cenv-lookup cenv name LEXICAL))
           (val (pass1 expr cenv)))
       (if (lvar? var)
         ($lset var val)
         ($gset (ensure-identifier var cenv) val))))
    (else
     (error "syntax-error: malformed set!:" form))))

;; Begin .....................................................

(define-pass1-syntax (begin form cenv) :null
  ($seq (map (cut pass1 <> cenv) (cdr form))))

;; Delay .....................................................

(define-pass1-syntax (delay form cenv) :null
  (match form
    ((_ expr)
     ($promise form (pass1 `(,lambda. () ,expr) cenv)))
    (else (error "syntax-error: malformed delay:" form))))

;; Module related ............................................

(define-pass1-syntax (define-module form cenv) :gauche
  (check-toplevel form cenv)
  (match form
    ((_ name body ...)
     (let* ((mod (ensure-module name 'define-module #t))
            (newenv (make-bottom-cenv mod)))
       (dynamic-wind
           (lambda () (vm-set-current-module mod))
           (lambda () ($seq (map (cut pass1 <> newenv) body)))
           (lambda () (vm-set-current-module (cenv-module cenv))))))
    (else
     (error "syntax-error: malformed define-module:" form))))

(define-pass1-syntax (with-module form cenv) :gauche
  (match form
    ((_ name body ...)
     (let* ((mod (ensure-module name 'with-module #f))
            (newenv (cenv-swap-module cenv mod)))
       (dynamic-wind
           (lambda () (vm-set-current-module mod))
           (lambda () ($seq (map (cut pass1 <> newenv) body)))
           (lambda () (vm-set-current-module (cenv-module cenv))))))
    (else
     (error "syntax-error: malformed with-module:" form))))

(define-pass1-syntax (select-module form cenv) :gauche
  (check-toplevel form cenv)
  (match form
    ((_ module)
     (vm-set-current-module (ensure-module module 'select-module #f))
     ($const-undef))
    (else (error "syntax-error: malformed select-module:" form))))

(define-pass1-syntax (current-module form cenv) :gauche
  (unless (null? (cdr form))
    (error "syntax-error: malformed current-module:" form))
  ($const (cenv-module cenv)))

(define-pass1-syntax (export form cenv) :gauche
  ($const (%export-symbols (cenv-module cenv) (cdr form))))

(define-pass1-syntax (import form cenv) :gauche
  ($const (%import-modules (cenv-module cenv) (cdr form))))

;; Black magic ........................................

(define-pass1-syntax (eval-when form cenv) :gauche
  (match form
    ((_ (w ...) expr ...)
     ;; check
     (let ((wlist
            (let loop ((w w) (r '()))
              (cond ((null? w) r)
                    ((memq (car w) '(:compile-toplevel :load-toplevel :execute))
                     (if (memq (car w) r)
                       (loop (cdr w) r)
                       (loop (cdr w) (cons (car w) r))))
                    (else
                     (error "eval-when: situation must be a list of :compile-toplevel, :load-toplevel or :execute, but got:" (car w))))))
           (situ (vm-eval-situation)))
       (when (and (eqv? situ SCM_VM_COMPILING)
                  (memq :compile-toplevel wlist)
                  (cenv-toplevel? cenv))
         (dolist (e expr) (eval e (cenv-module cenv))))
       (if (or (and (eqv? situ SCM_VM_LOADING)
                    (memq :load-toplevel wlist)
                    (cenv-toplevel? cenv))
               (and (eqv? situ SCM_VM_EXECUTING)
                    (memq :execute wlist)))
         ($seq (map (cut pass1 <> cenv) expr))
         ($const-undef))))
    (else (error "syntax-error: malformed eval-when:" form))))

;;===============================================================
;; Pass 2.  Optimization
;;

;; Walk down IForm and perform optimizations.
;; The main focus is to lift or inline closures, and eliminate
;; local frames by beta reduction.

;; This pass may modify the tree by changing IForm nodes destructively.

;; Each handler is called with three arguments: the IForm, Env, and Tail?
;;
;; Env is a list of $LAMBDA nodes that we're compiling.   It is used to
;; detect self-recursive local calls.  Tail? is a flag to indicate whether
;; the expression is tail position or not.

;; Dispatch pass2 handler.
;; *pass3-dispatch-table* is defined below, after all handlers are defined.
(define-inline (pass2/rec iform penv tail?)
  (let ((t (vector-ref *pass2-dispatch-table* (iform-tag iform))))
    (if t (t iform penv tail?) iform)))

(define (pass2 iform)
  (pass2/rec iform '() #t))

(define (pass2/$DEFINE iform penv tail?)
  ($define-expr-set! iform (pass2/rec ($define-expr iform) penv #f))
  iform)

;; LREF optimization.
;; Check if we can replace the $lref to its initial value.
;;  - If the lvar is never set!
;;     - if its init value is $const, just replace it
;;     - if its init value is $lref, replace it iff it is not set!,
;;       then repeat.
;;
;; There's a special LREF optimization when it appears in the operator
;; position.  If it is bound to $LAMBDA, we may be able to inline the
;; lambda.  It is dealt by pass2/head-lref, which is called by pass2/$CALL.

(define (pass2/$LREF iform penv tail?)
  (let1 lvar ($lref-lvar iform)
    (if (zero? (lvar-set-count lvar))
      (let1 initval (lvar-initval lvar)
        (cond ((not (vector? initval)) iform)
              ((has-tag? initval $CONST)
               (lvar-ref--! lvar)
               (vector-set! iform 0 $CONST)
               ($const-value-set! iform ($const-value initval))
               iform)
              ((and (has-tag? initval $LREF)
                    (zero? (lvar-set-count ($lref-lvar initval))))
               (lvar-ref--! lvar)
               (lvar-ref++! ($lref-lvar initval))
               ($lref-lvar-set! iform ($lref-lvar initval))
               (pass2/$LREF iform penv tail?))
              (else iform)))
      iform)))

(define (pass2/$LSET iform penv tail?)
  ($lset-expr-set! iform (pass2/rec ($lset-expr iform) penv #f))
  iform)

(define pass2/$GREF #f)

(define (pass2/$GSET iform penv tail?)
  ($gset-expr-set! iform (pass2/rec ($gset-expr iform) penv #f))
  iform)

(define pass2/$CONST #f)

(define pass2/$IT #f)

;; If optimization:
;;
;;  If the 'test' clause of $IF node contains another $IF that has $IT in
;;  either then or else clause, the straightforward code generation emits
;;  redundant jump/branch instructions.  We translate the tree into
;;  an acyclic directed graph:
;;
;;    ($if ($if <t0> ($it) <e0>) <then> <else>)
;;     => ($if <t0> #0=($label L0 <then>) ($if <e0> #0# <else>))
;;
;;    ($if ($if <t0> <e0> ($it)) <then> <else>)
;;    ($if ($if <t0> <e0> ($const #f)) <then> <else>)
;;     => ($if <t0> ($if <e0> <then> #0=($label L0 <else>)) #0#)
;;
;;    ($if ($if <t0> ($const #f) <e0>) <then> <else>)
;;     => ($if <t0> #0=($label L0 <else>) ($if <e0> <then> #0#))
;;        iff <else> != ($it)
;;     => ($if <t0> ($const #f) ($if <e0> <then> ($it)))
;;        iff <else> == ($it)
;;
;;  NB: If <then> or <else> clause is simple enough, we just duplicate
;;      it instead of creating $label node.  It is not only for optimization,
;;      but crucial when the clause is ($IT), since it affects the Pass3
;;      code generation stage.
;;
;;  NB: The latter two patterns may seem contrived, but it appears
;;      naturally in the 'cond' clause, e.g. (cond ((some-condition?) #f) ...)
;;      or (cond .... (else #f)).
;;
;;    ($if <t0> #0=($label ...) #0#)
;;     => ($seq <t0> ($label ...))
;;
;;  This form may appear as the result of if optimization.

(define (pass2/$IF iform penv tail?)
  (let1 test (pass2/rec ($if-test iform) penv #f)
    (or (and
         (has-tag? test $IF)
         (let ((test-then ($if-then test))
               (test-else ($if-else test)))
           (cond ((has-tag? test-then $IT)
                  (receive (l0 l1)
                      (pass2/label-or-dup
                       (pass2/rec ($if-then iform) penv tail?))
                    (pass2/update-if iform ($if-test test)
                                     l0
                                     (pass2/rec ($if #f
                                                     test-else
                                                     l1
                                                     ($if-else iform))
                                                penv tail?))))
                 ((or (has-tag? test-else $IT)
                      (and (has-tag? test-else $CONST)
                           (not ($const-value test-else))))
                  (receive (l0 l1)
                      (pass2/label-or-dup
                       (pass2/rec ($if-else iform) penv tail?))
                    (pass2/update-if iform ($if-test test)
                                     (pass2/rec ($if #f
                                                     test-then
                                                     ($if-then iform)
                                                     l0)
                                                penv tail?)
                                     l1)))
                 ((and (has-tag? test-then $CONST)
                       (not ($const-value test-then)))
                  (receive (l0 l1)
                      (pass2/label-or-dup
                       (pass2/rec ($if-else iform) penv tail?))
                    (pass2/update-if iform ($if-test test)
                                     (if (has-tag? l0 $IT)
                                       ($const #f)
                                       l0)
                                     (pass2/rec ($if #f
                                                     test-else
                                                     ($if-then iform)
                                                     l1)
                                                penv tail?))))
                 (else #f))))
        ;; default case
        (pass2/update-if iform
                         test
                         (pass2/rec ($if-then iform) penv tail?)
                         (pass2/rec ($if-else iform) penv tail?)))))

(define (pass2/label-or-dup iform)
  (if (memv (iform-tag iform) `(,$LREF ,$CONST ,$IT))
    (values iform (iform-copy iform '()))
    (let1 lab ($label #f #f iform)
      (values lab lab))))

(define (pass2/update-if iform new-test new-then new-else)
  (if (eq? new-then new-else)
    ($seq (list new-test new-then))
    (begin ($if-test-set! iform new-test)
           ($if-then-set! iform new-then)
           ($if-else-set! iform new-else)
           iform)))

;; Let optimization:
;;
;; - Unused variable elimination: if the bound lvars becomes unused by
;;   the result of $lref optimization, we eliminate it from the frame,
;;   and move its 'init' expression to the body.  if we're lucky, all
;;   the lvars introduced by this let are eliminated, and we can change
;;   this iform into a simple $seq.
;;
;; - Closure optimization: when an lvar is bound to a $LAMBDA node, we
;;   may be able to optimize the calls to it.  It is done here since
;;   we need to run pass2 for all the call sites of the lvar to analyze
;;   its usage.

(define (pass2/$LET iform penv tail?)
  (let ((lvars ($let-lvars iform))
        (inits (map (cut pass2/rec <> penv #f) ($let-inits iform)))
        (obody (pass2/rec ($let-body iform) penv tail?)))
    (for-each pass2/optimize-closure lvars inits)
    (receive (new-lvars new-inits removed-inits)
        (pass2/remove-unused-lvars lvars inits)
      (cond ((null? new-lvars)
             (if (null? removed-inits)
               obody
               ($seq (append! removed-inits (list obody)))))
            (else
             ($let-lvars-set! iform new-lvars)
             ($let-inits-set! iform new-inits)
             ($let-body-set! iform obody)
             (unless (null? removed-inits)
               (if (has-tag? obody $SEQ)
                 ($seq-body-set! obody
                                 (append! removed-inits
                                          ($seq-body obody)))
                 ($let-body-set! iform
                                 ($seq (append removed-inits
                                               (list obody))))))
             iform)))
    ))

(define (pass2/remove-unused-lvars lvars inits)
  (let loop ((lvars lvars) (inits inits) (rl '()) (ri '()) (rr '()))
    (cond ((null? lvars)
           (values (reverse! rl) (reverse! ri) (reverse! rr)))
          ((and (zero? (lvar-ref-count (car lvars)))
                (zero? (lvar-set-count (car lvars))))
           ;; TODO: if we remove $LREF from inits, we have to decrement
           ;; refcount?
           (loop (cdr lvars) (cdr inits) rl ri
                 (if (memv (iform-tag (car inits))
                           `(,$CONST ,$LREF ,$LAMBDA))
                   rr
                   (cons (car inits) rr))))
          (else
           (loop (cdr lvars) (cdr inits)
                 (cons (car lvars) rl) (cons (car inits) ri) rr)))))

;; Closure optimization (called from pass2/$LET)
;;
;;   Determine the strategy to optimize each closure, and modify the nodes
;;   accordingly.  We can't afford time to run iterative algorithm to find
;;   optimal strategy, so we take a rather simple-minded path to optimize
;;   common cases.
;;
;;   By now, we have the information of all call sites of the statically
;;   bound closures.   Each call site is marked as either REC, TAIL-REC
;;   or LOCAL.  See explanation of pass2/$CALL below.
;;
;;   Our objective is to categorize each call site to one of the following
;;   three options:
;;
;;     LOCAL: when we can't avoid creating a closure, calls to it are marked
;;     as "local".  The call to the local closure becomes a LOCAL-ENV-CALL
;;     instruction, which is faster than generic CALL/TAIL-CALL instructions.
;;
;;     EMBED: the lambda body is inlined at the call site.  It differs from
;;     the normal inlining in a way that we don't run beta-conversion of
;;     lrefs, since the body can be entered from other 'jump' call sites.
;;
;;     JUMP: the call becomes a LOCAL-ENV-JUMP instruction, i.e. a jump
;;     to the lambda body which is generated by the 'embed' call.
;;
;;   We can inline $LAMBDA if the following conditions are met:
;;
;;     1. The reference count of LVAR is equal to the number of call
;;        sites.  This means all use of this $LAMBDA is first-order,
;;        so we know the closure won't "leak out".
;;
;;     2. It doesn't have any REC call sites, i.e. non-tail self recursive
;;        calls.  (We may be able to convert non-tail self recursive calls
;;        to jump with environment adjustment, but it would complicates
;;        stack handling a lot.)
;;
;;     3. It doesn't have any TAIL-REC calls across closure boundary.
;;
;;         (letrec ((foo (lambda (...)
;;                           ..... (foo ...)) ;; ok
;;           ...
;;
;;         (letrec ((foo (lambda (...) ....
;;                         (lambda () ... (foo ...)) ;; not ok
;;           ...
;;
;;     4. Either:
;;         - It has only one LOCAL call, or
;;         - It doesn't have TAIL-REC calls and the body of $LAMBDA is
;;           small enough to duplicate.
;;
;;   If we determine $LAMBDA to be inlined, all LOCAL calls become EMBED
;;   calls, and TAIL-RECs become JUMP.
;;
;;   Otherwise, all calls become LOCAL calls.
;;

(define (pass2/optimize-closure lvar lambda-node)
  (when (and (zero? (lvar-set-count lvar))
             (> (lvar-ref-count lvar) 0)
             (has-tag? lambda-node $LAMBDA))
    (or (and (= (lvar-ref-count lvar) (length ($lambda-calls lambda-node)))
             (receive (locals recs tail-recs)
                 (pass2/classify-calls ($lambda-calls lambda-node) lambda-node)
               (and (null? recs)
                    (pair? locals)
                    (or (and (null? (cdr locals))
                             (pass2/local-call-embedder lvar lambda-node
                                                        (car locals)
                                                        tail-recs))
                        (and (null? tail-recs)
                             (< (iform-count-size-upto lambda-node
                                                       SMALL_LAMBDA_SIZE)
                                SMALL_LAMBDA_SIZE)
                             (pass2/local-call-inliner lvar lambda-node
                                                       locals))))))
        (pass2/local-call-optimizer lvar lambda-node)
        )))

;; Classify the calls into categories.  TAIL-REC call is classified as
;; REC if the call is across the closure boundary.
(define (pass2/classify-calls call&envs lambda-node)
  (define (direct-call? env)
    (let loop ((env env))
      (cond ((null? env) #t)
            ((eq? (car env) lambda-node) #t)
            ((eq? ($lambda-flag (car env)) 'dissolved)
             (loop (cdr env))) ;; skip dissolved (inlined) lambdas
            (else #f))))
  (let loop ((call&envs call&envs)
             (local '())
             (rec '())
             (trec '()))
    (match call&envs
      (()
       (values local rec trec))
      (((call . env) . more)
       (case ($call-flag call)
         ((tail-rec)
          (if (direct-call? env)
            (loop more local rec (cons call trec))
            (loop more local (cons call rec) trec)))
         ((rec) (loop more local (cons call rec) trec))
         (else  (loop more (cons call local) rec trec)))))
    ))

;; Set up local calls to LAMBDA-NODE.  Marking $call node as 'local
;; lets pass3 to generate LOCAL-ENV-CALL instruction.
(define (pass2/local-call-optimizer lvar lambda-node)
  (let ((reqargs ($lambda-reqargs lambda-node))
        (optarg  ($lambda-optarg lambda-node))
        (name    ($lambda-name lambda-node))
        (calls   ($lambda-calls lambda-node)))
    (dolist (call calls)
      ($call-args-set! (car call)
                       (adjust-arglist reqargs optarg
                                       ($call-args (car call))
                                       name))
      ($call-flag-set! (car call) 'local))
    ;; We clear the calls list, just in case if the lambda-node is
    ;; traversed more than once.
    ($lambda-calls-set! lambda-node '())))

;; Called when the local function (lambda-node) isn't needed to be a closure
;; and can be embedded.
;; NB: this operation introduces a shared/circular structure in the IForm.
(define (pass2/local-call-embedder lvar lambda-node call rec-calls)
  (let ((reqargs ($lambda-reqargs lambda-node))
        (optarg  ($lambda-optarg lambda-node))
        (name    ($lambda-name lambda-node))
        )
    ($call-args-set! call (adjust-arglist reqargs optarg ($call-args call)
                                          name))
    (lvar-ref--! lvar)
    ($call-flag-set! call 'embed)
    ($call-proc-set! call lambda-node)
    ;($lambda-flag-set! lambda-node 'dissolved)
    (unless (null? rec-calls)
      (let1 body
          ($label ($lambda-src lambda-node) #f ($lambda-body lambda-node))
        ($lambda-body-set! lambda-node body)
        (dolist (call rec-calls)
          (lvar-ref--! lvar)
          ($call-args-set! call (adjust-arglist reqargs optarg
                                                ($call-args call)
                                                name))
          ($call-proc-set! call body)
          ($call-flag-set! call 'jump))))))

;; Called when the local function (lambda-node) doesn't have recursive
;; calls, can be inlined, and called from multiple places.
;; NB: This inlining would introduce quite a few redundant $LETs and
;; we want to run LREF beta-conversion again.  It means one more path.
;; Maybe we'd do that in the future version.
;; NB: Here we destructively modify $call node to change it to $seq,
;; in order to hold the $LET node.  It breaks the invariance that $seq
;; contains zero or two or more nodes---this may prevent Pass 3 from
;; doing some optimization.
(define (pass2/local-call-inliner lvar lambda-node calls)
  (define (inline-it call-node lambda-node)
    (let1 inlined (expand-inlined-procedure ($*-src lambda-node) lambda-node
                                            ($call-args call-node))
      (vector-set! call-node 0 $SEQ)
      (if (has-tag? inlined $SEQ)
        ($seq-body-set! call-node ($seq-body inlined))
        ($seq-body-set! call-node (list inlined)))))
  
  (lvar-ref-count-set! lvar 0)
  ;($lambda-flag-set! lambda-node 'dissolved)
  (let loop ((calls calls))
    (cond ((null? (cdr calls))
           (inline-it (car calls) lambda-node))
          (else
           (inline-it (car calls) (iform-copy lambda-node '()))
           (loop (cdr calls))))))

(define (pass2/$RECEIVE iform penv tail?)
  ($receive-expr-set! iform (pass2/rec ($receive-expr iform) penv #f))
  ($receive-body-set! iform (pass2/rec ($receive-body iform) penv tail?))
  iform)

(define (pass2/$LAMBDA iform penv tail?)
  ($lambda-body-set! iform (pass2/rec ($lambda-body iform)
                                      (cons iform penv) #t))
  iform)

(define (pass2/$LABEL iform penv tail?)
  ;; $LABEL's body should already be processed by pass2, so we don't need
  ;; to do it again.
  iform)

(define (pass2/$PROMISE iform penv tail?)
  ($promise-expr-set! iform (pass2/rec ($promise-expr iform) penv #f))
  iform)

(define (pass2/$SEQ iform penv tail?)
  (if (null? ($seq-body iform))
    iform
    (let loop ((body ($seq-body iform))
               (r '()))
      (cond ((null? (cdr body))
             ($seq-body-set! iform
                             (reverse! (cons (pass2/rec (car body) penv tail?)
                                             r)))
             iform)
            (else
             (loop (cdr body)
                   (cons (pass2/rec (car body) penv #f) r)))))))

;; Call optimization
;;   We try to inline the call whenever possible.
;;
;;   1. If proc is $LAMBDA, we turn the whole struct into $LET.
;;
;;        ($call ($lambda .. (LVar ...) Body) Arg ...)
;;         => ($let (LVar ...) (Arg ...) Body)
;;
;;   2. If proc is $LREF which is statically bound to a $LAMBDA,
;;      call pass2/head-lref to see if we can safely inline it.
;;
;;   The second case has several subcases.
;;    2a. Some $LAMBDA nodes can be directly inlined, e.g. the whole
;;        $CALL node can be turned into $LET node.  The original $LAMBDA
;;        node vanishes if all the calls to the $LAMBDA node are first-order.
;;
;;        ($call ($lref lvar0) Arg ...)
;;          where lvar0 => ($lambda .... (LVar ...) Body)
;;
;;         => ($let (LVar ...) (Arg ...) Body)
;;
;;    2b. When $LAMBDA node is recursively called, or is called multiple
;;        times, we need more information to determine how to optimize it.
;;        So at this moment we just mark the $CALL node, and pushes
;;        it and the current penv to the 'calls' slot of the $LAMBDA node.
;;        After we finish Pass 2 of the scope of lvar0, we can know how to
;;        optimize the $LAMBDA node, and those $CALL nodes are revisited
;;        and modified accordingly.
;;
;;        If the $CALL node is a non-recursive local call, the $CALL node
;;        is marked as 'local'.  If it is a recursive call, it is marked
;;        as 'rec'.

(define (pass2/$CALL iform penv tail?)
  (cond
   (($call-flag iform) iform) ;; this node has already been visited.
   (else
    ;; scan OP first to give an opportunity of variable renaming
    ($call-proc-set! iform (pass2/rec ($call-proc iform) penv #f))
    (let ((proc ($call-proc iform))
          (args ($call-args iform)))
      (cond
       ((vm-compiler-flag-is-set? SCM_COMPILE_NOINLINE_LOCALS)
        ($call-args-set! iform (map (cut pass2/rec <> penv #f) args))
        iform)
       ((has-tag? proc $LAMBDA) ;; ((lambda (...) ...) arg ...)
        (pass2/rec (expand-inlined-procedure ($*-src iform) proc args)
                   penv tail?))
       ((and (has-tag? proc $LREF)
             (pass2/head-lref proc penv tail?))
        => (lambda (result)
             (cond
              ((vector? result)
               ;; Directly inlinable case.  NB: this only happens if the $LREF
               ;; node is the lvar's single reference, so we know the inlined
               ;; procedure is never called recursively.  Thus we can safely
               ;; travarse the inlined body without going into infinite loop.
               (pass2/rec (expand-inlined-procedure ($*-src iform) result args)
                          penv tail?))
              (else
               ;; We need more info to decide optimizing this node.  For now,
               ;; we mark the call node by the returned flag and push it
               ;; to the $LAMBDA node.
               (let1 lambda-node (lvar-initval ($lref-lvar proc))
                 ($call-flag-set! iform result)
                 ($lambda-calls-set! lambda-node
                                     (acons iform penv
                                            ($lambda-calls lambda-node)))
                 ($call-args-set! iform (map (cut pass2/rec <> penv #f) args))
                 iform)))))
       (else
        ($call-args-set! iform (map (cut pass2/rec <> penv #f) args))
        iform))))
   ))

;; Check if IFORM ($LREF node) can be a target of procedure-call optimization.
;;   - If IFORM is not statically bound to $LAMBDA node,
;;     returns #f.
;;   - If the $LAMBDA node that can be directly inlined, returns
;;     the $LAMBDA node.
;;   - If the call is self-recursing, returns 'tail-rec or 'rec, depending
;;     on whether this call is tail call or not.
;;   - Otherwise, returns 'local.

(define (pass2/head-lref iform penv tail?)
  (and-let* ((lvar ($lref-lvar iform))
             ( (zero? (lvar-set-count lvar)) )
             (initval (lvar-initval lvar))
             ( (vector? initval) )
             ( (has-tag? initval $LAMBDA) )
             )
    (cond
     ((pass2/self-recursing? initval penv) (if tail? 'tail-rec 'rec))
     ((= (lvar-ref-count lvar) 1)
      ;; we can inline this lambda directly.
      (lvar-ref--! lvar)
      (lvar-initval-set! lvar ($const-undef))
      initval)
     (else 'local))))

(define (pass2/self-recursing? node penv)
  (find (cut eq? node <>) penv))

(define (pass2/$ASM iform penv tail?)
  ($asm-args-set! iform (map (cut pass2/rec <> penv #f)
                             ($asm-args iform)))
  iform)

(define (pass2/onearg-inliner iform penv tail?)
  ($*-arg0-set! iform (pass2/rec ($*-arg0 iform) penv #f))
  iform)

(define pass2/$LIST->VECTOR pass2/onearg-inliner)

(define (pass2/twoarg-inliner iform penv tail?)
  ($*-arg0-set! iform (pass2/rec ($*-arg0 iform) penv #f))
  ($*-arg1-set! iform (pass2/rec ($*-arg1 iform) penv #f))
  iform)

(define pass2/$CONS   pass2/twoarg-inliner)
(define pass2/$APPEND pass2/twoarg-inliner)
(define pass2/$MEMV   pass2/twoarg-inliner)
(define pass2/$EQ?    pass2/twoarg-inliner)
(define pass2/$EQV?   pass2/twoarg-inliner)

(define (pass2/narg-inliner iform penv tail?)
  ($*-args-set! iform (map (cut pass2/rec <> penv #f) ($*-args iform)))
  iform)

(define pass2/$LIST   pass2/narg-inliner)
(define pass2/$LIST*  pass2/narg-inliner)
(define pass2/$VECTOR pass2/narg-inliner)

;; Dispatch table.
(define-macro (pass2-generate-dispatch-table)
  `(vector ,@(map (lambda (p) (string->symbol #`"pass2/,(car p)"))
                  .intermediate-tags.)))

(define *pass2-dispatch-table* (pass2-generate-dispatch-table))

;;===============================================================
;; Pass 3.  Code generation
;;

;; This pass pushes down a runtime environment, renv.  It is
;; a nested list of lvars, and used to generate LREF/LSET instructions.
;; 
;; The context, ctx, is either one of the following symbols.
;;
;;   normal/bottom : the FORM is evaluated in the context that the
;;            stack has no pending arguments (i.e. a continuation
;;            frame is just pushed).
;;   normal/top : the FORM is evaluated, while there are pending
;;            arguments in the stack top.  Such premature argument frame
;;            should be protected if VM calls something that may
;;            capture the continuation.
;;   stmt/bottom : Like normal/bottom, but the result of FORM won't
;;            be used.
;;   stmt/top : Like normal/top, but the result of FORM won't be used.
;;   tail   : FORM is evaluated in the tail context.  It is always
;;            bottom.
;;
;; Each IForm node handler generates the code by side-effects.  Besides
;; the code generation, each handler returns the maximum stack depth.


;; predicate
(define (normal-context? ctx) (memq ctx '(normal/bottm normal/top)))
(define (stmt-context? ctx)   (memq ctx '(stmt/bottm stmt/top)))
(define (tail-context? ctx)   (eq? ctx 'tail))
(define (bottom-context? ctx) (memq ctx '(normal/bottom stmt/bottom tail)))
(define (top-context? ctx)    (memq ctx '(normal/top stmt/top)))

;; context switch 
(define (normal-context prev-ctx)
  (if (bottom-context? prev-ctx) 'normal/bottom 'normal/top))

(define (stmt-context prev-ctx)
  (if (bottom-context? prev-ctx) 'stmt/bottom 'stmt/top))

(define (tail-context prev-ctx) 'tail)

;; Emit instruction and an optional operand.   Instruction combination
;; is handled here.
(define (pass3/emit! ccb insn operand info)
  (let-syntax ((replace!
                (syntax-rules ()
                  ((_ insn) (compiled-code-replace-insn! ccb insn #f #f))
                  ((_ insn operand)
                   (compiled-code-replace-insn! ccb insn operand #f))
                  ((_ insn operand info)
                   (compiled-code-replace-insn! ccb insn operand info))))
               (put!
                (syntax-rules ()
                  ((_ insn) (compiled-code-put-insn! ccb insn operand info))))
               )
    (case/unquote
     (car insn)
     ((LREF)
      (if (and (<= 0 (cadr insn) 1)   ;; depth
               (<= 0 (caddr insn) 4)) ;; offset
        (put! (vector-ref `#((,LREF0)  (,LREF1)  (,LREF2)  (,LREF3)  (,LREF4)
                             (,LREF10) (,LREF11) (,LREF12) (,LREF13) (,LREF14))
                          (+ (* (cadr insn) 5) (caddr insn))))
        (put! insn)))
     ((LSET)
      (if (and (= (cadr insn) 0)      ;; depth
               (<= 0 (caddr insn) 4)) ;; offset
        (put! (vector-ref `#((,LSET0) (,LSET1) (,LSET2) (,LSET3) (,LSET4))
                          (caddr insn)))
        (put! insn)))
     ((PUSH)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (case/unquote
           (car pinsn)
           ((LREF0)  (replace! `(,LREF0-PUSH)))
           ((LREF1)  (replace! `(,LREF1-PUSH)))
           ((LREF2)  (replace! `(,LREF2-PUSH)))
           ((LREF3)  (replace! `(,LREF3-PUSH)))
           ((LREF4)  (replace! `(,LREF4-PUSH)))
           ((LREF10) (replace! `(,LREF10-PUSH)))
           ((LREF11) (replace! `(,LREF11-PUSH)))
           ((LREF12) (replace! `(,LREF12-PUSH)))
           ((LREF13) (replace! `(,LREF13-PUSH)))
           ((LREF14) (replace! `(,LREF14-PUSH)))
           ((LREF)   (replace! `(,LREF-PUSH ,@(cdr pinsn))))
           ((GREF)   (replace! `(,GREF-PUSH) poperand))
           ((CAR)    (replace! `(,CAR-PUSH)))
           ((CDR)    (replace! `(,CDR-PUSH)))
           ((CAAR)   (replace! `(,CAAR-PUSH)))
           ((CDAR)   (replace! `(,CDAR-PUSH)))
           ((CADR)   (replace! `(,CADR-PUSH)))
           ((CDDR)   (replace! `(,CDDR-PUSH)))
           ((CONS)   (replace! `(,CONS-PUSH)))
           ((CONST)  (replace! `(,CONST-PUSH) poperand))
           ((CONSTI) (replace! `(,CONSTI-PUSH ,@(cdr pinsn))))
           ((CONSTN) (replace! `(,CONSTN-PUSH)))
           ((CONSTF) (replace! `(,CONSTF-PUSH)))
           (else (put! insn))))))
     ((CONST)
      (cond
       ((null? operand)      (put! `(,CONSTN)))
       ((not operand)        (put! `(,CONSTF)))
       ((undefined? operand) (put! `(,CONSTU)))
       ((integer-fits-insn-arg? operand) (put! `(,CONSTI ,operand)))
       (else (put! insn))))
     ((CALL TAIL-CALL)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (case/unquote
           (car pinsn)
           ((GREF)
            (replace! `(,(if (eqv? (car insn) CALL) GREF-CALL GREF-TAIL-CALL)
                        ,(cadr insn))
                      poperand info))
           ((PUSH-GREF)
            (replace! `(,(if (eqv? (car insn) CALL)
                           PUSH-GREF-CALL
                           PUSH-GREF-TAIL-CALL)
                        ,(cadr insn))
                      poperand info))
           (else
            (put! insn))))))
     ((PRE-CALL)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (if (eqv? (car pinsn) PUSH)
            (replace! `(,PUSH-PRE-CALL ,(cadr insn)) operand info)
            (put! insn)))))
     ((GREF)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (if (eqv? (car pinsn) PUSH)
            (replace! `(,PUSH-GREF) operand)
            (put! insn)))))
     ((LOCAL-ENV)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (if (eqv? (car pinsn) PUSH)
            (replace! `(,PUSH-LOCAL-ENV ,(cadr insn)))
            (put! insn)))))
     ((RET)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (case/unquote
           (car pinsn)
           ((CONST)  (replace! `(,CONST-RET) poperand))
           ((CONSTF) (replace! `(,CONSTF-RET)))
           ((CONSTU) (replace! `(,CONSTU-RET)))
           (else (put! insn))))))
     ((CAR)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (case/unquote
           (car pinsn)
           ((CAR) (replace! `(,CAAR)))
           ((CDR) (replace! `(,CADR)))
           (else (put! insn))))))
     ((CDR)
      (receive (pinsn poperand) (compiled-code-current-insn ccb)
        (if (not pinsn)
          (put! insn)
          (case/unquote
           (car pinsn)
           ((CAR) (replace! `(,CDAR)))
           ((CDR) (replace! `(,CDDR)))
           (else (put! insn))))))
     (else (put! insn)))
    ))

;; Dispatch pass3 handler.
;; *pass3-dispatch-table* is defined below, after all handlers are defined.
(define-inline (pass3/rec iform ccb renv ctx)
  ((vector-ref *pass3-dispatch-table* (vector-ref iform 0))
   iform ccb renv ctx))

;;
;; Pass 3 main entry
;;
(define (pass3 iform initial-renv reqargs optargs name parent intform)
  (let* ((ccb (make-compiled-code-builder reqargs optargs name parent intform))
         (maxstack (pass3/rec iform ccb initial-renv 'tail)))
    (pass3/emit! ccb `(,RET) #f #f)
    (compiled-code-finish-builder ccb maxstack)
    ccb))

;;
;; Pass 3 intermediate tree handlers
;;

(define (pass3/$DEFINE iform ccb renv ctx)
  (let ((d (pass3/rec ($define-expr iform) ccb '() 'normal/bottom))
        (f (if (memq 'const ($define-flags iform)) 1 0)))
    (pass3/emit! ccb `(,DEFINE ,f) ($define-id iform) ($*-src iform))
    d))

(define (pass3/$LREF iform ccb renv ctx)
  (receive (depth offset) (pass3/lookup-lvar ($lref-lvar iform) renv ctx)
    (pass3/emit! ccb `(,LREF ,depth ,offset) #f
                 (lvar-name ($lref-lvar iform)))
    0))

(define (pass3/$LSET iform ccb renv ctx)
  (receive (depth offset) (pass3/lookup-lvar ($lset-lvar iform) renv ctx)
    (let1 d (pass3/rec ($lset-expr iform) ccb renv (normal-context ctx))
      (pass3/emit! ccb `(,LSET ,depth ,offset) #f
                   (lvar-name ($lset-lvar iform)))
      d)))

(define (pass3/$GREF iform ccb renv ctx)
  (let1 id ($gref-id iform)
    (pass3/emit! ccb `(,GREF) id id)
    0))

(define (pass3/$GSET iform ccb renv ctx)
  (let ((d (pass3/rec ($gset-expr iform) ccb renv (normal-context ctx)))
        (id ($gset-id iform)))
    (pass3/emit! ccb `(,GSET) id id)
    d))

(define (pass3/$CONST iform ccb renv ctx)
  ;; if the context is stmt-context, value won't be used so we drop it.
  (unless (stmt-context? ctx)
    (pass3/emit! ccb `(,CONST) ($const-value iform) #f))
  0)

;; Branch peephole optimization
;;   We have variations of conditional branch instructions for typical
;;   cases.  In this handler we select an appropriate instructions.
;;
;;   Sometimes we want to inverse the test, swapping then and else,
;;   if we can strip extra NOT operation.  Note that it is only possible
;;   if the result of test isn't used directly (that is, neither then nor
;;   else clause is ($IT)), thus we treat such a case specially.
(define (pass3/$IF iform ccb renv ctx)
  (cond
   ((and (not (has-tag? ($if-then iform) $IT))
         (not (has-tag? ($if-else iform) $IT))
         (has-tag? ($if-test iform) $ASM)
         (eqv? (car ($asm-insn ($if-test iform))) NOT))
    (pass3/$IF ($if ($*-src iform)
                    (car ($asm-args ($if-test iform)))
                    ($if-else iform)
                    ($if-then iform))
               ccb renv ctx))
   (else
    (pass3/branch-core iform ccb renv ctx))))

(define (pass3/branch-core iform ccb renv ctx)
  (let1 test ($if-test iform)
    ;; Select an appropriate branch instruction
    (cond
     ((has-tag? test $ASM)
      (let ((code (car ($asm-insn test))); ASM code
            (args ($asm-args test)))
        (cond
         ((eqv? code NULLP)
          (pass3/if-final iform (car args) `(,BNNULL) 0 
                          ($*-src test) ccb renv ctx))
         ((eqv? code EQ)
          (pass3/if-eq iform (car args) (cadr args)
                       ($*-src test) ccb renv ctx))
         ((eqv? code EQV)
          (pass3/if-eqv iform (car args) (cadr args)
                        ($*-src test) ccb renv ctx))
         ((eqv? code NUMEQ2)
          (pass3/if-numeq iform (car args) (cadr args)
                          ($*-src test) ccb renv ctx))
         ((eqv? code NUMLE2)
          (pass3/if-numcmp iform (car args) (cadr args)
                           BNLE ($*-src test) ccb renv ctx))
         ((eqv? code NUMLT2)
          (pass3/if-numcmp iform (car args) (cadr args)
                           BNLT ($*-src test) ccb renv ctx))
         ((eqv? code NUMGE2)
          (pass3/if-numcmp iform (car args) (cadr args)
                           BNGE ($*-src test) ccb renv ctx))
         ((eqv? code NUMGT2)
          (pass3/if-numcmp iform (car args) (cadr args)
                           BNGT ($*-src test) ccb renv ctx))
         (else
          (pass3/if-final iform test `(,BF) 0 ($*-src iform) ccb renv ctx))
         )))
     ((has-tag? test $EQ?)
      (pass3/if-eq iform ($*-arg0 test) ($*-arg1 test)
                   ($*-src iform) ccb renv ctx))
     ((has-tag? test $EQV?)
      (pass3/if-eqv iform ($*-arg0 test) ($*-arg1 test)
                    ($*-src iform) ccb renv ctx))
     (else
      (pass3/if-final iform test `(,BF) 0 ($*-src iform) ccb renv ctx))
     )))

;; 
(define (pass3/if-eq iform x y info ccb renv ctx)
  (cond
   ((has-tag? x $CONST)
    (pass3/if-final iform y `(,BNEQC ,($const-value x)) 0
                    info ccb renv ctx))
   ((has-tag? y $CONST)
    (pass3/if-final iform x `(,BNEQC ,($const-value y)) 0
                    info ccb renv ctx))
   (else
    (let1 depth (max (pass3/rec x ccb renv (normal-context ctx)) 1)
      (pass3/emit! ccb `(,PUSH) #f #f)
      (pass3/if-final iform y `(,BNEQ) depth
                      info ccb renv ctx)))))

(define (pass3/if-eqv iform x y info ccb renv ctx)
  (cond
   ((has-tag? x $CONST)
    (pass3/if-final iform y `(,BNEQVC ,($const-value x)) 0
                    info ccb renv ctx))
   ((has-tag? y $CONST)
    (pass3/if-final iform x `(,BNEQVC ,($const-value y)) 0
                    info ccb renv ctx))
   (else
    (let1 depth (max (pass3/rec x ccb renv (normal-context ctx)) 1)
      (pass3/emit! ccb `(,PUSH) #f #f)
      (pass3/if-final iform y `(,BNEQV) depth
                      info ccb renv ctx)))))

(define (pass3/if-numeq iform x y info ccb renv ctx)
  (or (and (has-tag? x $CONST)
           (integer-fits-insn-arg? ($const-value x))
           (pass3/if-final iform y `(,BNUMNEI ,($const-value x)) 0
                           info ccb renv ctx))
      (and (has-tag? y $CONST)
           (integer-fits-insn-arg? ($const-value y))
           (pass3/if-final iform x `(,BNUMNEI ,($const-value y)) 0
                           info ccb renv ctx))
      (let1 depth (max (pass3/rec x ccb renv (normal-context ctx)) 1)
        (pass3/emit! ccb `(,PUSH) #f #f)
        (pass3/if-final iform y `(,BNUMNE) depth info ccb renv ctx))))

(define (pass3/if-numcmp iform x y insn info ccb renv ctx)
  (let1 depth (max (pass3/rec x ccb renv (normal-context ctx)) 1)
    (pass3/emit! ccb `(,PUSH) #f #f)
    (pass3/if-final iform y `(,insn) depth
                    info ccb renv ctx)))

;; Final stage of emitting branch instruction.
;; Optimization
;;   - tail context
;;      - if insn is (BF)
;;        - then part is ($IT)  => use RT
;;        - else part is ($IT)  => use RF
;;      - otherwise, place RET after then clause
;;   - otherwise
;;      - else part is ($IT)  => we can omit a jump after then clause
;;      - otherwise, merge the control after this node.

(define-constant .branch-insn-extra-operand.
  `(,BNEQC ,BNEQVC))

(define (pass3/if-final iform test insn depth info ccb renv ctx)
  (let1 depth (max (pass3/rec test ccb renv (normal-context ctx)) depth)
    (cond
     ((tail-context? ctx)
      (cond
       ((and (eqv? (car insn) BF)
             (has-tag? ($if-then iform) $IT))
        (pass3/emit! ccb `(,RT) #f info)
        (max (pass3/rec ($if-else iform) ccb renv ctx) depth))
       ((and (eqv? (car insn) BF)
             (has-tag? ($if-else iform) $IT))
        (pass3/emit! ccb `(,RF) #f info)
        (max (pass3/rec ($if-then iform) ccb renv ctx) depth))
       (else
        (let ((elselabel (compiled-code-new-label ccb)))
          (if (memv (car insn) .branch-insn-extra-operand.)
            (pass3/emit! ccb (list (car insn)) (list (cadr insn) elselabel)
                         info)
            (pass3/emit! ccb insn elselabel info))
          (set! depth (max (pass3/rec ($if-then iform) ccb renv ctx) depth))
          (pass3/emit! ccb `(,RET) #f #f)
          (compiled-code-set-label! ccb elselabel)
          (max (pass3/rec ($if-else iform) ccb renv ctx) depth)))))
     (else
      (let ((elselabel  (compiled-code-new-label ccb))
            (mergelabel (compiled-code-new-label ccb)))
        (if (memv (car insn) .branch-insn-extra-operand.)
          (pass3/emit! ccb (list (car insn)) (list (cadr insn) elselabel)
                       info)
          (pass3/emit! ccb insn elselabel info))
        (set! depth (max (pass3/rec ($if-then iform) ccb renv ctx) depth))
        (unless (has-tag? ($if-else iform) $IT)
          (pass3/emit! ccb `(,JUMP) mergelabel #f))
        (compiled-code-set-label! ccb elselabel)
        (unless (has-tag? ($if-else iform) $IT)
          (set! depth (max (pass3/rec ($if-else iform) ccb renv ctx) depth)))
        (compiled-code-set-label! ccb mergelabel)
        depth)))))

(define (pass3/$IT iform ccb renv ctx) 0)

;; $LET stack estimate
;;   normal let: Each init clause is evaluated while preceding results
;;     of inits are on the stack.  Pass3/prepare-args returns the maximum
;;     stack depth from the initial position of the stack (i.e. it considers
;;     accumulating values).  After all inits are evaluated, we complete
;;     the env frame and run the body.
;;
;;   letrec: We create the env frame before evaluating inits, so the max
;;     stack is: total env frame size + max of stack depth consumed by
;;     one of inits or the body.
;;

(define (pass3/$LET iform ccb renv ctx)
  (let ((info ($*-src iform))
        (lvars ($let-lvars iform))
        (inits ($let-inits iform))
        (body  ($let-body iform))
        (merge-label (if (bottom-context? ctx)
                       #f
                       (compiled-code-new-label ccb))))
    (let1 nlocals (length lvars)
      (case ($let-type iform)
        ((let)
         (cond
          ((bottom-context? ctx)
           (let1 dinit (pass3/prepare-args inits ccb renv ctx)
             (pass3/emit! ccb `(,LOCAL-ENV ,nlocals) #f info)
             (let1 dbody (pass3/rec body ccb (cons lvars renv) ctx)
               (unless (tail-context? ctx)
                 (pass3/emit! ccb `(,POP-LOCAL-ENV) #f #f))
               (max dinit (+ dbody ENV_HEADER_SIZE nlocals)))))
          (else
           (pass3/emit! ccb `(,PRE-CALL ,nlocals) merge-label #f)
           (let1 dinit (pass3/prepare-args inits ccb renv ctx)
             (pass3/emit! ccb `(,LOCAL-ENV ,nlocals) #f info)
             (let1 dbody (pass3/rec body ccb (cons lvars renv) 'tail)
               (pass3/emit! ccb `(,RET) #f #f)
               (compiled-code-set-label! ccb merge-label)
               (max dinit
                    (+ dbody CONT_FRAME_SIZE ENV_HEADER_SIZE nlocals))))
           )))
        ((rec)
         (receive (closures others)
             (partition-letrec-inits inits ccb (cons lvars renv) 0 '() '())
           (cond
            ((bottom-context? ctx)
             (pass3/emit! ccb `(,LOCAL-ENV-CLOSURES ,nlocals) closures info)
             (let* ((dinit (emit-letrec-inits others nlocals ccb
                                              (cons lvars renv) 0))
                    (dbody (pass3/rec body ccb (cons lvars renv) ctx)))
               (unless (tail-context? ctx)
                 (pass3/emit! ccb `(,POP-LOCAL-ENV) #f #f))
               (+ ENV_HEADER_SIZE nlocals (max dinit dbody))))
            (else
             (pass3/emit! ccb `(,PRE-CALL ,nlocals) merge-label #f)
             (pass3/emit! ccb `(,LOCAL-ENV-CLOSURES ,nlocals) closures info)
             (let* ((dinit (emit-letrec-inits others nlocals ccb
                                              (cons lvars renv) 0))
                    (dbody (pass3/rec body ccb (cons lvars renv) 'tail)))
               (pass3/emit! ccb `(,RET) #f #f)
               (compiled-code-set-label! ccb merge-label)
               (+ CONT_FRAME_SIZE ENV_HEADER_SIZE nlocals
                  (max dinit dbody)))))))
        (else
         (error "[internal error]: pass3/$LET got unknown let type:"
                ($let-type iform)))
        ))))

(define (partition-letrec-inits inits ccb renv cnt closures others)
  (if (null? inits)
    (values (reverse! closures) (reverse! others))
    (let1 init (car inits)
      (cond
       ((has-tag? init $LAMBDA)
        (let1 args ($lambda-lvars init)
          (partition-letrec-inits (cdr inits) ccb renv (+ cnt 1)
                                  (cons (pass3 ($lambda-body init)
                                               (if (null? args)
                                                 renv
                                                 (cons args renv))
                                               ($lambda-reqargs init)
                                               ($lambda-optarg init)
                                               ($lambda-name init)
                                               ccb #f)
                                        closures)
                                  others)))
       ((has-tag? init $CONST)
        (partition-letrec-inits (cdr inits) ccb renv (+ cnt 1)
                                (cons ($const-value init) closures)
                                others))
       (else
        (partition-letrec-inits (cdr inits) ccb renv (+ cnt 1)
                                (cons (undefined) closures)
                                (acons cnt init others)))))))

(define (emit-letrec-inits init-alist nlocals ccb renv depth)
  (if (null? init-alist)
    depth
    (let* ((off&expr (car init-alist))
           (d (pass3/rec (cdr off&expr) ccb renv 'normal/bottom)))
      (pass3/emit! ccb `(,LSET 0 ,(- nlocals 1 (car off&expr))) #f #f)
      (emit-letrec-inits (cdr init-alist) nlocals ccb renv
                         (max depth d)))))

(define (pass3/$RECEIVE iform ccb renv ctx)
  (let ((nargs  ($receive-reqargs iform))
        (optarg ($receive-optarg iform))
        (lvars  ($receive-lvars iform))
        (expr   ($receive-expr iform))
        (body   ($receive-body iform)))
    (cond
     ((bottom-context? ctx)
      (let1 dinit (pass3/rec expr ccb renv (normal-context ctx))
        (pass3/emit! ccb `(,TAIL-RECEIVE ,nargs ,optarg) #f ($*-src iform))
        (let1 dbody (pass3/rec body ccb (cons lvars renv) ctx)
          (unless (tail-context? ctx)
            (pass3/emit! ccb `(,POP-LOCAL-ENV) #f #f))
          (max dinit (+ nargs optarg ENV_HEADER_SIZE dbody)))))
     (else
      (let ((merge-label (compiled-code-new-label ccb))
            (dinit (pass3/rec expr ccb renv (normal-context ctx))))
        (pass3/emit! ccb `(,RECEIVE ,nargs ,optarg) merge-label ($*-src iform))
        (let1 dbody (pass3/rec body ccb (cons lvars renv) 'tail)
          (pass3/emit! ccb `(,RET) #f #f)
          (compiled-code-set-label! ccb merge-label)
          (max dinit (+ nargs optarg CONT_FRAME_SIZE ENV_HEADER_SIZE dbody)))))
     )))

(define (pass3/$LAMBDA iform ccb renv ctx)
  (let1 body
      (pass3 ($lambda-body iform)
             (if (null? ($lambda-lvars iform))
               renv
               (cons ($lambda-lvars iform) renv))
             ($lambda-reqargs iform) ($lambda-optarg iform)
             ($lambda-name iform)
             ccb
             (case ($lambda-flag iform)
               ((inlined) (pack-iform iform))
               (else #f)))
    (pass3/emit! ccb `(,CLOSURE) body ($*-src iform))
    0))

(define (pass3/$LABEL iform ccb renv ctx)
  (let ((label ($label-label iform)))
    ;; NB: $LABEL node in the PROC position of $CALL node is handled by $CALL.
    (cond
     (label
      (pass3/emit! ccb `(,JUMP) label ($*-src iform))
      0)
     (else
      (compiled-code-set-label! ccb (pass3/ensure-label ccb iform))
      (pass3/rec ($label-body iform) ccb renv ctx)))))

(define (pass3/$SEQ iform ccb renv ctx)
  (let1 exprs ($seq-body iform)
    (cond
     ((null? exprs) 0)
     ((null? (cdr exprs)) (pass3/rec (car exprs) ccb renv ctx))
     (else
      (let loop ((exprs exprs) (depth 0))
        (if (null? (cdr exprs))
          (max (pass3/rec (car exprs) ccb renv ctx) depth)
          (loop (cdr exprs)
                (max (pass3/rec (car exprs) ccb renv (stmt-context ctx))
                     depth)))))
     )))

;; $CALL.
;;  There are several variations in $CALL node.  Each variation may also
;;  have tail-call version and non-tail-call version. 
;;  
;;  1. Local call: a $CALL node that has 'local' flag is a call to known
;;     local procedure.  Its arguments are already adjusted to match the
;;     signature of the procedure.   PROC slot contains an LREF node that
;;     points to the local procedure.
;;
;;  2. Embedded call: a $CALL node that has 'embed' flag is a control
;;     transfer to an inlined local procedure, whose entry point may be
;;     called from more than one place (Cf. an inlined procedure that is
;;     called only once becomes $LET node, so we don't need to consider it).
;;     Its arguments are already adjusted to match the signature of the
;;     procedure.  Its PROC slot contains the embedded $LAMBDA node, whose
;;     body is $LABEL node.
;;     The generated code is almost the same as $LET node, except that a
;;     label is placed just after LOCAL-ENV.
;;
;;  3. Jump call: a $CALL node that has 'jump' flag is a control transfer
;;     to an inlined local procedure, and whose body is embedded in somewhere
;;     else (by an 'embedded call' node).   The PROC slot contains a $LABEL
;;     node.  We emit LOCAL-ENV-JUMP instruction for this type of node.
;;
;;  4. Head-heavy call: a $CALL node without any flag, and all the
;;     arguments are simple expressions (e.g. const or lref), but the
;;     operator expression has $LET.  The normal calling sequence evaluates
;;     the operator expression after pushing arguments.  That causes the
;;     $LET be evaluated in 'top' context, which requires pushing
;;     extra continuation.  If all the arguments are simple, we can evaluate
;;     the operator expression first, and keeping it in VAL0 while pushing
;;     the arguments.
;;     Notably, a named let expression tends to become a head-heavy call,
;;     so it is worth to treat it specially.
;;     Note that this head-heavy call optimization relies on the arguments
;;     to use combined instructions such as CONST-PUSH or LREF-PUSH.  If
;;     the instruction combination is turned off, we can't use this since
;;     VAL0 is overwritten by arguments.
;;
;;  5. Other call node generates the standard calling sequence.
;;

;; stack depth of $CALL nodes:
;;  - if nargs >= 1, we need (# of args) + (env header) slots
;;  - if generic call, +2 for possible object-apply hack and next-method.
;;  - if non-tail call, + CONT_FRAME_SIZE.

(define (pass3/$CALL iform ccb renv ctx)
  (case ($call-flag iform)
    ((local) (pass3/local-call iform ccb renv ctx))
    ((embed) (pass3/embed-call iform ccb renv ctx))
    ((jump)  (pass3/jump-call  iform ccb renv ctx))
    (else
     (if (and (bottom-context? ctx)
              (has-tag? ($call-proc iform) $LET)
              (all-args-simple? ($call-args iform)))
       (pass3/head-heavy-call iform ccb renv ctx)
       (pass3/normal-call iform ccb renv ctx)))))

;; Local call
;;   PROC is always $LREF.
(define (pass3/local-call iform ccb renv ctx)
  (let* ((args ($call-args iform))
         (nargs (length args)))
    (if (tail-context? ctx)
      (let1 dinit (pass3/prepare-args args ccb renv ctx)
        (pass3/rec ($call-proc iform) ccb renv 'normal/top)
        (pass3/emit! ccb `(,LOCAL-ENV-TAIL-CALL ,nargs) #f ($*-src iform))
        (if (= nargs 0)
          0
          (max dinit (+ nargs ENV_HEADER_SIZE))))
      (let1 merge-label (compiled-code-new-label ccb)
        (pass3/emit! ccb `(,PRE-CALL ,nargs) merge-label #f)
        (let1 dinit (pass3/prepare-args args ccb renv ctx)
          (pass3/rec ($call-proc iform) ccb renv 'normal/top)
          (pass3/emit! ccb `(,LOCAL-ENV-CALL ,nargs) #f ($*-src iform))
          (compiled-code-set-label! ccb merge-label)
          (if (= nargs 0)
            CONT_FRAME_SIZE
            (max dinit (+ nargs ENV_HEADER_SIZE CONT_FRAME_SIZE))))))))


;; Embedded call
;;  - We need to push the continuation even if we're at the tail
;;    context, since there may be an env frame on top of the stack
;;    which will be clobbered by LOCAL-ENV-JUMP if we don't protect
;;    it.  In future, we can track whether the stack top has
;;    env frame or not, and emit PRE-CALL instruction selectively.
(define (pass3/embed-call iform ccb renv ctx)
  (let* ((proc ($call-proc iform))
         (args ($call-args iform))
         (nargs (length args))
         (label ($lambda-body proc))
         (newenv (if (= nargs 0)
                   renv
                   (cons ($lambda-lvars proc) renv)))
         (merge-label (compiled-code-new-label ccb)))
    (pass3/emit! ccb `(,PRE-CALL ,nargs) merge-label #f)
    (let1 dinit
        (if (> nargs 0)
          (let1 d (pass3/prepare-args args ccb renv ctx)
            (pass3/emit! ccb `(,LOCAL-ENV ,nargs) #f ($*-src iform))
            d)
          0)
      (compiled-code-set-label! ccb (pass3/ensure-label ccb label))
      (let1 dbody (pass3/rec ($label-body label) ccb newenv 'tail)
        (pass3/emit! ccb `(,RET) #f #f)
        (compiled-code-set-label! ccb merge-label)
        (if (= nargs 0)
          (+ CONT_FRAME_SIZE dbody)
          (max dinit (+ nargs ENV_HEADER_SIZE CONT_FRAME_SIZE dbody)))))
    ))

;; Jump call
;; NB: we're not sure whether we'll have non-tail jump call yet.
(define (pass3/jump-call iform ccb renv ctx)
  (let* ((args ($call-args iform))
         (nargs (length args)))
    (if (tail-context? ctx)
      (let1 dinit (pass3/prepare-args args ccb renv ctx)
        (pass3/emit! ccb `(,LOCAL-ENV-JUMP ,nargs)
                     (pass3/ensure-label ccb ($call-proc iform))
                     ($*-src iform))
        (if (= nargs 0) 0 (max dinit (+ nargs ENV_HEADER_SIZE))))
      (let1 merge-label (compiled-code-new-label ccb)
        (pass3/emit! ccb `(,PRE-CALL ,nargs) merge-label #f)
        (let1 dinit (pass3/prepare-args args ccb renv ctx)
          (pass3/emit! ccb `(,LOCAL-ENV-JUMP ,nargs)
                       (pass3/ensure-label ccb ($call-proc iform))
                       ($*-src iform))
          (compiled-code-set-label! ccb merge-label)
          (if (= nargs 0)
            CONT_FRAME_SIZE
            (max dinit (+ nargs ENV_HEADER_SIZE CONT_FRAME_SIZE)))))
      )))

;; Head-heavy call
(define (pass3/head-heavy-call iform ccb renv ctx)
  (let* ((args ($call-args iform))
         (nargs (length args)))
    (if (tail-context? ctx)
      (let* ((dproc (pass3/rec ($call-proc iform)
                               ccb renv (normal-context ctx)))
             (dinit (pass3/prepare-args args ccb renv 'normal/top)))
        (pass3/emit! ccb `(,TAIL-CALL ,nargs) #f ($*-src iform))
        (max dinit (+ nargs dproc ENV_HEADER_SIZE)))
      (let1 merge-label (compiled-code-new-label ccb)
        (pass3/emit! ccb `(,PRE-CALL ,nargs) merge-label #f)
        (let* ((dproc (pass3/rec ($call-proc iform)
                                 ccb renv (normal-context ctx)))
               (dinit (pass3/prepare-args args ccb renv 'normal/top)))
          (pass3/emit! ccb `(,CALL ,nargs) #f ($*-src iform))
          (compiled-code-set-label! ccb merge-label)
          (+ CONT_FRAME_SIZE (max dinit (+ nargs dproc ENV_HEADER_SIZE)))))
      )))

;; Normal call
(define (pass3/normal-call iform ccb renv ctx)
  (let* ((args ($call-args iform))
         (nargs (length args)))
    (if (tail-context? ctx)
      (let* ((dinit (pass3/prepare-args args ccb renv ctx))
             (dproc (pass3/rec ($call-proc iform) ccb renv 'normal/top)))
        (pass3/emit! ccb `(,TAIL-CALL ,nargs) #f ($*-src iform))
        (max dinit (+ nargs dproc ENV_HEADER_SIZE)))
      (let1 merge-label (compiled-code-new-label ccb)
        (pass3/emit! ccb `(,PRE-CALL ,nargs) merge-label #f)
        (let* ((dinit (pass3/prepare-args args ccb renv ctx))
               (dproc (pass3/rec ($call-proc iform) ccb renv 'normal/top)))
          (pass3/emit! ccb `(,CALL ,nargs) #f ($*-src iform))
          (compiled-code-set-label! ccb merge-label)
          (+ CONT_FRAME_SIZE (max dinit (+ nargs dproc ENV_HEADER_SIZE)))))
      )))

(define (all-args-simple? args)
  (cond ((null? args) #t)
        ((memv (iform-tag (car args)) `(,$LREF ,$CONST))
         (all-args-simple? (cdr args)))
        (else #f)))

(define (pass3/ensure-label ccb label-node)
  (or ($label-label label-node)
      (let1 lab (compiled-code-new-label ccb)
        ($label-label-set! label-node lab)
        lab)))

;; $ASMs.  For some instructions, we may pick more specialized one
;; depending on its arguments.

(define (pass3/$ASM iform ccb renv ctx)
  (let ((info ($*-src iform))
        (insn ($asm-insn iform))
        (args ($asm-args iform)))
    (case/unquote
     (car insn)
     ((EQ)
      (pass3/asm-eq  info (car args) (cadr args) ccb renv ctx))
     ((EQV)
      (pass3/asm-eqv info (car args) (cadr args) ccb renv ctx))
     ((NUMEQ2)
      (pass3/asm-numeq2 info (car args) (cadr args) ccb renv ctx))
     ((NUMLT2 NUMLE2 NUMGT2 NUMGE2)
      (pass3/asm-numcmp info (car insn) (car args) (cadr args) ccb renv ctx))
     ((NUMADD2)
      (pass3/asm-numadd2 info (car args) (cadr args) ccb renv ctx))
     ((NUMSUB2)
      (pass3/asm-numsub2 info (car args) (cadr args) ccb renv ctx))
     ((NUMMUL2)
      (pass3/asm-nummul2 info (car args) (cadr args) ccb renv ctx))
     ((NUMDIV2)
      (pass3/asm-numdiv2 info (car args) (cadr args) ccb renv ctx))
     ((VEC-REF)
      (pass3/asm-vec-ref info (car args) (cadr args) ccb renv ctx))
     ((VEC-SET)
      (pass3/asm-vec-set info (car args) (cadr args) (caddr args) ccb renv ctx))
     ((SLOT-REF)
      (pass3/asm-slot-ref info (car args) (cadr args) ccb renv ctx))
     ((SLOT-SET)
      (pass3/asm-slot-set info (car args) (cadr args) (caddr args) ccb renv ctx))
     (else
      ;; general case
      (case (length args)
        ((0) (pass3/emit! ccb insn #f info) 0)
        ((1)
         (let1 d (pass3/rec (car args) ccb renv 'normal/top)
           (pass3/emit! ccb insn #f info)
           d))
        ((2)
         (let1 d0 (pass3/rec (car args) ccb renv 'normal/top)
           (pass3/emit! ccb `(,PUSH) #f #f)
           (let1 d1 (pass3/rec (cadr args) ccb renv 'normal/top)
             (pass3/emit! ccb insn #f info)
             (max d0 (+ d1 1)))))
        (else
         (let loop ((args args) (depth 0) (cnt 0))
           (cond ((null? (cdr args))
                  (let1 d (pass3/rec (car args) ccb renv 'normal/top)
                    (pass3/emit! ccb insn #f info)
                    (max depth (+ cnt d))))
                 (else
                  (let1 d (pass3/rec (car args) ccb renv 'normal/top)
                    (pass3/emit! ccb `(,PUSH) #f #f)
                    (loop (cdr args) (max depth (+ d cnt)) (+ cnt 1)))))))
        )))))

(define (pass3/$PROMISE iform ccb renv ctx)
  (let1 d (pass3/rec ($promise-expr iform) ccb renv (normal-context ctx))
    (pass3/emit! ccb `(,PROMISE) #f ($*-src iform))
    d))

(define (pass3/$CONS iform ccb renv ctx)
  (pass3/builtin-twoargs ccb ($*-src iform) `(,CONS)
                         ($*-arg0 iform) ($*-arg1 iform)
                         renv ctx))

(define (pass3/$APPEND iform ccb renv ctx)
  (pass3/builtin-twoargs ccb ($*-src iform) `(,APPEND 2)
                         ($*-arg0 iform) ($*-arg1 iform)
                         renv ctx))

(define (pass3/$LIST iform ccb renv ctx)
  (pass3/builtin-nargs ccb ($*-src iform) LIST ($*-args iform) renv ctx))

(define (pass3/$LIST* iform ccb renv ctx)
  (pass3/builtin-nargs ccb ($*-src iform) LIST-STAR ($*-args iform) renv ctx))

(define (pass3/$VECTOR iform ccb renv ctx)
  (pass3/builtin-nargs ccb ($*-src iform) VEC ($*-args iform) renv ctx))

(define (pass3/$LIST->VECTOR iform ccb renv ctx)
  (pass3/builtin-onearg ccb ($*-src iform) `(,LIST2VEC)
                        ($*-arg0 iform) renv ctx))

(define (pass3/$MEMV iform ccb renv ctx)
  (pass3/builtin-twoargs ccb ($*-src iform) `(,MEMV)
                         ($*-arg0 iform) ($*-arg1 iform)
                         renv ctx))

(define (pass3/$EQ? iform ccb renv ctx)
  (pass3/asm-eq ($*-src iform) ($*-arg0 iform) ($*-arg1 iform)
                ccb renv ctx))

(define (pass3/$EQV? iform ccb renv ctx)
  (pass3/asm-eqv ($*-src iform) ($*-arg0 iform) ($*-arg1 iform)
                 ccb renv ctx))

;; handlers to emit specialized instruction when applicable

(define (pass3/asm-eq info x y ccb renv ctx)
  (pass3/builtin-twoargs ccb info `(,EQ) x y renv ctx))

(define (pass3/asm-eqv info x y ccb renv ctx)
  (pass3/builtin-twoargs ccb info `(,EQV) x y renv ctx))

(define (pass3/asm-numeq2 info x y ccb renv ctx)
  (pass3/builtin-twoargs ccb info `(,NUMEQ2) x y renv ctx))

(define (pass3/asm-numcmp info insn x y ccb renv ctx)
  (pass3/builtin-twoargs ccb info `(,insn) x y renv ctx))

(define (pass3/asm-numadd2 info x y ccb renv ctx)
  (or (and (has-tag? x $CONST)
           (integer-fits-insn-arg? ($const-value x))
           (pass3/builtin-onearg ccb info `(,NUMADDI ,($const-value x))
                                 y renv ctx))
      (and (has-tag? y $CONST)
           (integer-fits-insn-arg? ($const-value y))
           (pass3/builtin-onearg ccb info `(,NUMADDI ,($const-value y))
                                 x renv ctx))
      (pass3/builtin-twoargs ccb info `(,NUMADD2) x y renv ctx)))

(define (pass3/asm-numsub2 info x y ccb renv ctx)
  (or (and (has-tag? x $CONST)
           (integer-fits-insn-arg? ($const-value x))
           (pass3/builtin-onearg ccb info `(,NUMSUBI ,($const-value x))
                                 y renv ctx))
      (and (has-tag? y $CONST)
           (integer-fits-insn-arg? ($const-value y))
           (pass3/builtin-onearg ccb info
                                 `(,NUMADDI ,(- ($const-value y)))
                                 x renv ctx))
      (pass3/builtin-twoargs ccb info `(,NUMSUB2) x y renv ctx)))

(define (pass3/asm-nummul2 info x y ccb renv ctx)
  (pass3/builtin-twoargs ccb info `(,NUMMUL2) x y renv ctx))

(define (pass3/asm-numdiv2 info x y ccb renv ctx)
  (pass3/builtin-twoargs ccb info `(,NUMDIV2) x y renv ctx))


(define (pass3/asm-vec-ref info vec k ccb renv ctx)
  (cond ((and (has-tag? k $CONST)
              (unsigned-integer-fits-insn-arg? ($const-value k)))
         (pass3/builtin-onearg ccb info `(,VEC-REFI ,($const-value k))
                               vec renv ctx))
        (else
         (pass3/builtin-twoargs ccb info `(,VEC-REF) vec k renv ctx))))

(define (pass3/asm-vec-set info vec k obj ccb renv ctx)
  (cond ((and (has-tag? k $CONST)
              (unsigned-integer-fits-insn-arg? ($const-value k)))
         (pass3/builtin-twoargs ccb info `(,VEC-SETI ,($const-value k))
                                vec obj renv ctx))
        (else
         (let1 d0 (pass3/rec vec ccb renv (normal-context ctx))
           (pass3/emit! ccb `(,PUSH) #f #f)
           (let1 d1 (pass3/rec k   ccb renv 'normal/top)
             (pass3/emit! ccb `(,PUSH) #f #f)
             (let1 d2 (pass3/rec obj ccb renv 'normal/top)
               (pass3/emit! ccb `(,VEC-SET) #f info)
               (max d0 (+ d1 1) (+ d2 2))))))))

(define (pass3/asm-slot-ref info obj slot ccb renv ctx)
  (cond ((has-tag? slot $CONST)
         (let1 d (pass3/rec obj ccb renv (normal-context ctx))
           (pass3/emit! ccb `(,SLOT-REFC) ($const-value slot) info)
           d))
        (else
         (pass3/builtin-twoargs ccb info `(,SLOT-REF) obj slot renv ctx))))

(define (pass3/asm-slot-set info obj slot val ccb renv ctx)
  (cond ((has-tag? slot $CONST)
         (let1 d0 (pass3/rec obj ccb renv (normal-context ctx))
           (pass3/emit! ccb `(,PUSH) #f #f)
           (let1 d1 (pass3/rec val ccb renv 'normal/top)
             (pass3/emit! ccb `(,SLOT-SETC) ($const-value slot) info)
             (max d0 (+ d1 1)))))
        (else
         (let1 d0 (pass3/rec obj ccb renv (normal-context ctx))
           (pass3/emit! ccb `(,PUSH) #f #f)
           (let1 d1 (pass3/rec slot ccb renv 'normal/top)
             (pass3/emit! ccb `(,PUSH) #f #f)
             (let1 d2 (pass3/rec val ccb renv 'normal/top)
               (pass3/emit! ccb `(,SLOT-SET) #f info)
               (max d0 (+ d1 1) (+ d2 2))))))))

;; Dispatch table.
(define-macro (pass3-generate-dispatch-table)
  `(vector ,@(map (lambda (p) (string->symbol #`"pass3/,(car p)"))
                  .intermediate-tags.)))

(define *pass3-dispatch-table* (pass3-generate-dispatch-table))
     
;; Returns depth and offset of local variable reference.
;; NB: for the time being, we manually extract the inner loop
;; to the toplevel.  The original versio is in the comment below.
;; Turn it back once we implemented tail call inliner.

(define (pass3/lookup-lvar lvar renv ctx)
  (pass3/lookup-lvar-outer lvar renv 0 ctx))

(define (pass3/lookup-lvar-outer lvar renv depth ctx)
  (if (null? renv)
    (error "[internal error] stray local variable:" lvar)
    (pass3/lookup-lvar-inner lvar (car renv) renv 1 depth ctx)))

(define (pass3/lookup-lvar-inner lvar frame renv count depth ctx)
  (cond
   ((null? frame)
    (pass3/lookup-lvar-outer lvar (cdr renv) (+ depth 1) ctx))
   ((eq? (car frame) lvar)
    (values depth (- (length (car renv)) count)))
   (else
    (pass3/lookup-lvar-inner lvar (cdr frame) renv (+ count 1) depth ctx))))

;(define (pass3/lookup-lvar lvar renv ctx)
;  (let outer ((renv renv)
;              (depth 0))
;    (if (null? renv)
;      (error "[internal error] stray local variable:" lvar)
;      (let inner ((frame (car renv))
;                  (count 1))
;        (cond ((null? frame) (outer (cdr renv) (+ depth 1)))
;              ((eq? (car frame) lvar)
;               (values depth (- (length (car renv)) count)))
;              (else (inner (cdr frame) (+ count 1))))))))

(define (pass3/prepare-args args ccb renv ctx)
  (if (null? args)
    0
    (let1 d (pass3/rec (car args) ccb renv (normal-context ctx))
      (pass3/emit! ccb `(,PUSH) #f #f)
      (pass3/prepare-args-rest (cdr args) ccb renv ctx (+ d 1) 1))))

(define (pass3/prepare-args-rest args ccb renv ctx depth cnt)
  (if (null? args)
    depth
    (let1 d (pass3/rec (car args) ccb renv 'normal/top)
      (pass3/emit! ccb `(,PUSH) #f #f)
      (pass3/prepare-args-rest (cdr args) ccb renv ctx
                               (max depth (+ d cnt 1)) (+ cnt 1)))))

(define (pass3/builtin-twoargs ccb info insn arg0 arg1 renv ctx)
  (let1 d0 (pass3/rec arg0 ccb renv (normal-context ctx))
    (pass3/emit! ccb `(,PUSH) #f #f)
    (let1 d1 (pass3/rec arg1 ccb renv 'normal/top)
      (pass3/emit! ccb insn #f info)
      (max d0 (+ d1 1)))))

(define (pass3/builtin-onearg ccb info insn arg0 renv ctx)
  (let1 d (pass3/rec arg0 ccb renv (normal-context ctx))
    (pass3/emit! ccb insn #f info)
    d))

(define (pass3/builtin-onearg/operand ccb info insn operand arg0 renv ctx)
  (let1 d (pass3/rec arg0 ccb renv (normal-context ctx))
    (pass3/emit! ccb insn operand info)
    d))

(define (pass3/builtin-nargs ccb info insn args renv ctx)
  (if (null? args)
    (begin (pass3/emit! ccb (list insn 0) #f info) 0)
    (let loop ((as args) (depth 0) (cnt 0))
      (cond ((null? (cdr as))
             (let1 d (pass3/rec (car as) ccb renv 'normal/top)
               (pass3/emit! ccb (list insn (length args)) #f info)
               (max (+ d cnt) depth)))
            (else
             (let1 d (pass3/rec (car as) ccb renv 'normal/top)
               (pass3/emit! ccb `(,PUSH) #f #f)
               (loop (cdr as) (max (+ d cnt) depth) (+ cnt 1))))))))

;;============================================================
;; Inliners of builtin procedures
;;

;; If the subr has a directly corresponding VM instruction, the
;; inlining direction is embedded within the subr definition in
;; the stub file.  The inliners below deal with more complex
;; situations.

;; Some operations (e.g. NUMADD2) has specialized instructions when
;; one of the operands has certain properties (e.g. if one of the operand
;; is a small exact integer, NUMADDI can be used).  Such choice of
;; instructions are done in Pass 3 $ASM handler, since they may have
;; more information.  The inliner can emit a generic instruction and
;; leave the choice of specialized instructions to the later stage.

;; Defines builtin inliner for the existing SUBRs.
;; The binding of NAME must be visible from gauche.internal.
(define-macro (define-builtin-inliner name proc)
  (let1 debug-name (string->symbol #`"inliner/,name")
    `(let1 ,debug-name ,proc
       (set! (%procedure-inliner ,name) ,debug-name))))

;; Some useful utilities
;;
(define (asm-arg1 form insn x cenv)
  ($asm form insn (list (pass1 x cenv))))

(define (asm-arg2 form insn x y cenv)
  ($asm form insn (list (pass1 x cenv) (pass1 y cenv))))

(define (gen-inliner-arg2 insn)
  (lambda (form cenv)
    (match form
      ((_ x y) (asm-arg2 form (list insn) x y cenv))
      (else (undefined)))))

;;--------------------------------------------------------
;; Inlining numeric operators
;;

;; (1) VM insturctions are usually binary where the corresponding
;;  Scheme operators are variable arity.  We analyze the arguments
;;  and generate a (possibly nested) $asm clause.
;;
;; (2) We try to fold constant operations.  Constant numbers may appear
;;  literally, or a result of constant-variable compilation or other
;;  constant folding.   Except the literal numbers we need to call
;;  pass1 first on the argument to see if we can get a constant.

;; Utility.  Returns two values.  The first value is a number, if
;; the given form yields a constant number.  The second value is
;; an intermediate form, if the given form is not a literal.
(define (check-numeric-constant form cenv)
  (if (number? form)
    (values form #f)
    (let1 f (pass1 form cenv)
      (if (and (has-tag? f $CONST) (number? ($const-value f)))
        (values ($const-value f) f)
        (values #f f)))))

(define-builtin-inliner +
  (lambda (form cenv)
    (let inline ((args (cdr form)))
      (match args
        (()  ($const 0))
        ((x)
         (receive (num tree) (check-numeric-constant x cenv)
           (if num
             (or tree ($const num))
             ($call form ($gref (ensure-identifier '+ cenv)) (list tree) #f))))
        ((x y . more)
         (receive (xval xtree) (check-numeric-constant x cenv)
           (receive (yval ytree) (check-numeric-constant y cenv)
             (if xval
               (if yval
                 (inline (cons (+ xval yval) more))
                 (fold-inline-+ form ytree (cons xval more) cenv))
               (if yval
                 (fold-inline-+ form xtree (cons yval more) cenv)
                 (fold-inline-+ form ($asm form `(,NUMADD2) (list xtree ytree))
                                more cenv))))))
        ))))

(define (fold-inline-+ form asm rest cenv)
  (if (null? rest)
    asm
    (receive (val tree) (check-numeric-constant (car rest) cenv)
      (fold-inline-+ form
                     ($asm form `(,NUMADD2)
                           (list asm (or tree ($const val))))
                     (cdr rest) cenv))))

(define-builtin-inliner -
  (lambda (form cenv)
    (let inline ((args (cdr form)))
      (match args
        (()
         (error "procedure - requires at least one argument:" form))
        ((x)
         (receive (num tree) (check-numeric-constant x cenv)
           (if num
             (or tree ($const (- num)))
             ($asm form `(,NEGATE) (list tree)))))
        ((x y . more)
         (receive (xval xtree) (check-numeric-constant x cenv)
           (receive (yval ytree) (check-numeric-constant y cenv)
             (if xval
               (if yval
                 (if (null? more)
                   ($const (- xval yval))
                   (inline (cons (- xval yval) more)))
                 (fold-inline-- form
                                ($asm form `(,NUMSUB2)
                                      (list (or xtree ($const xval)) ytree))
                                more cenv))
               (fold-inline-- form
                              ($asm form `(,NUMSUB2)
                                    (list xtree (or ytree ($const yval))))
                              more cenv)))))
        ))))

(define (fold-inline-- form asm rest cenv)
  (if (null? rest)
    asm
    (receive (val tree) (check-numeric-constant (car rest) cenv)
      (fold-inline-- form
                     ($asm form `(,NUMSUB2)
                           (list asm (or tree ($const val))))
                     (cdr rest) cenv))))

(define-builtin-inliner *
  (lambda (form cenv)
    (let inline ((args (cdr form)))
      (match args
        (()  ($const 1))
        ((x)
         (receive (num tree) (check-numeric-constant x cenv)
           (if (number? num)
             (or tree ($const num))
             ($call form ($gref (ensure-identifier '* cenv)) (list tree) #f))))
        ((x y . more)
         (receive (xval xtree) (check-numeric-constant x cenv)
           (receive (yval ytree) (check-numeric-constant y cenv)
             (if (and xval yval)
               (inline (cons (* xval yval) more))
               (fold-inline-* form
                              ($asm form `(,NUMMUL2)
                                    (list (or xtree ($const xval))
                                          (or ytree ($const yval))))
                              more cenv))))))
      )))

(define (fold-inline-* form asm rest cenv)
  (if (null? rest)
    asm
    (fold-inline-* form
                   ($asm form `(,NUMMUL2) (list asm (pass1 (car rest) cenv)))
                   (cdr rest) cenv)))

(define-builtin-inliner /
  (lambda (form cenv)
    (let inline ((args (cdr form)))
      (match args
        (()
         (error "procedure / requires at least one argument:" form))
        ((x)
         (receive (num tree) (check-numeric-constant x cenv)
           (if (number? num)
             ($const (/ num))
             ($call form ($gref (ensure-identifier '/ cenv)) (list tree) #f))))
        ((x y . more)
         (receive (xval xtree) (check-numeric-constant x cenv)
           (receive (yval ytree) (check-numeric-constant y cenv)
             (if (and xval yval)
               (if (null? more)
                 ($const (/ xval yval))
                 (inline (cons (/ xval yval) more)))
               (fold-inline-/ form
                              ($asm form `(,NUMDIV2)
                                    (list (or xtree ($const xval))
                                          (or ytree ($const yval))))
                              more cenv))))))
      )))

(define (fold-inline-/ form asm rest cenv)
  (if (null? rest)
    asm
    (fold-inline-/ form
                   ($asm form `(,NUMDIV2) (list asm (pass1 (car rest) cenv)))
                   (cdr rest) cenv)))

(define-builtin-inliner =   (gen-inliner-arg2 NUMEQ2))
(define-builtin-inliner <   (gen-inliner-arg2 NUMLT2))
(define-builtin-inliner <=  (gen-inliner-arg2 NUMLE2))
(define-builtin-inliner >   (gen-inliner-arg2 NUMGT2))
(define-builtin-inliner >=  (gen-inliner-arg2 NUMGE2))

;;--------------------------------------------------------
;; Inlining other operators
;;

(define-builtin-inliner vector-ref
  (lambda (form cenv)
    (match form
      ((_ vec ind)
       (asm-arg2 form `(,VEC-REF) vec ind cenv))
      (else (undefined)))))

(define-builtin-inliner vector-set!
  (lambda (form cenv)
    (match form
      ((_ vec ind val)
       ($asm form `(,VEC-SET) `(,(pass1 vec cenv)
                                ,(pass1 ind cenv)
                                ,(pass1 val cenv))))
      (else (error "wrong number of arguments for vector-set!:" form)))))

;;============================================================
;; Utilities
;;

;; see if the immediate integer value fits in the insn arg.
(define (integer-fits-insn-arg? obj)
  (and (integer? obj)
       (exact? obj)
       (<= #x-7ffff obj #x7ffff)))

(define (unsigned-integer-fits-insn-arg? obj)
  (and (integer? obj)
       (exact? obj)
       (<= 0 obj #x7ffff)))

(define (variable-name arg)
  (cond ((symbol? arg) arg)
        ((identifier? arg) (slot-ref arg 'name))
        ((lvar? arg) (lvar-name arg))
        (else (error "variable required, but got:" arg))))

(define (global-eq? var sym cenv)
  (and (variable? var)
       (let1 v (cenv-lookup cenv var LEXICAL)
         (cond
          ((identifier? v)
           (and (eq? (slot-ref v 'name) sym)
                (null? (slot-ref v 'env))))
          ((symbol? v) (eq? v sym))
          (else #f)))))

(define (global-eq?? sym cenv)
  (cut global-eq? <> sym cenv))

;;============================================================
;; Initialization
;;

(define (init-compiler)
  #f
  )
  
