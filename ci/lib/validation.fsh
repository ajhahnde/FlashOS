def validation_error(prefix, message) {
    ^printf '%s: %s\n' $prefix $message 1>&2
    exit 1
}

def require_nonempty(value, prefix, label) {
    if $value == null || $value == '' {
        validation_error($prefix, "$label must not be empty")
    }
    return $value
}

def require_positive_integer(value, prefix, label) {
    let residue = "$(^printf '%sX' $value | ^tr -d '0-9')"
    if !$status.ok {
        validation_error($prefix, "cannot validate $label")
    }
    if $value == '0' || $residue != 'X' {
        validation_error($prefix, "$label must be a positive integer")
    }
    return $value
}

# Structured validators call these helpers inside `from json | each`. They
# throw data-only errors so the owning root can map the message to its exact
# public diagnostic after the internal pipeline has unwound.
def expect_equal(observed, expected, message) {
    if $observed != $expected {
        throw $message
    }
    return $observed
}

def expect_nonempty_list(values, message) {
    if $values == [] {
        throw $message
    }
    return $values
}

def expect_unique(values, message) {
    for selected in $values {
        mut occurrences = 0
        for candidate in $values {
            if $candidate == $selected {
                $occurrences = $occurrences + 1
            }
        }
        if $occurrences != 1 {
            throw $message
        }
    }
    return $values
}

export {
    expect_equal,
    expect_nonempty_list,
    expect_unique,
    require_nonempty,
    require_positive_integer,
    validation_error,
}
