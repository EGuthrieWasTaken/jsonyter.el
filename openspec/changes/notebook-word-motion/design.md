# Design

A word character cannot begin or end a string, a comment or a paired
delimiter, so keeping it does not undo what the inert table is for. The
non-ASCII half is taken from the standard syntax table rather than guessed:
accented and CJK letters are words there, and non-ASCII punctuation is not,
which avoids the "everything above 127 is a word" trade-off. `_` stays
punctuation, as every other non-alphanumeric character does, so `snake_case`
stops at the underscore the way it does in a code cell of most languages.
