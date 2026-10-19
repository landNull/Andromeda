<?php
/**
 * @file
 * Parse error on purpose. Capcom /fixloop and php -l should catch this.
 */

function stress_bad_broken_example($value) {
  $out = "missing semicolon"
  return $out
}
