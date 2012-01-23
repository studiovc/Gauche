;; Test gauche.lazy
;;  gauche.lazy isn't precompiled (yet), but it depends on gauche.generator
;;  so we test it here.

(use gauche.test)
(use gauche.generator)
(test-start "lazy sequence utilities")

(use gauche.lazy)
(test-module 'gauche.lazy)

(let ()
  (define (test-eager-lazy name l e . args)
    (test* #`"eager vs lazy (,name)" (apply e args) (apply l args)))

  (test-eager-lazy "lmap" lmap map (^x (* x x)) '(1 2 3 4 5))
  (test-eager-lazy "lmap" lmap map (^(x y) (+ x y)) '(1 2 3 4 5) '(2 3 4 5))
  (test-eager-lazy "lappend" lappend append '() '(1) '(1 2 3))
  (test-eager-lazy "lappend" lappend append)
  (test-eager-lazy "lappend" lappend append '())
  )

(test* "lazyness - coercion" '(1 2 3 4 5)
       (lmap identity '#(1 2 3 4 5)))
(test* "lazyness - coercion" '(#\a #\b #\c #\d #\e)
       (lmap identity "abcde"))

(test* "lazyness - lmap" 0
       ;; this yields an error if lmap works eagerly.
       (list-ref (lmap (^x (quotient 1 x)) '(1 2 3 4 0)) 2))

(test-end)
