<?php
/**
 * @file
 * Broken autocomplete. Capcom should fix this: missing helper, returns a PHP array.
 */

/**
 * Broken callback. Calls a function that does not exist and returns the wrong type.
 */
function stress_bad_autocomplete_broken($string = '') {
  $matches = stress_bad_missing_helper($string);
  return $matches;
}
