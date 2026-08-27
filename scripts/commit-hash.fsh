#!/usr/bin/env fsh

# Report the current Git commit of every checked-out system recipe source.

def status_code(completion: Status) -> Int {
    if $completion.code != null {
        return $completion.code
    }
    if $completion.signal != null {
        if $completion.signal.number != null {
            return 128 + $completion.signal.number
        }
    }
    1
}

if ^test -d recipes/core {
} else {
    ^printf '%s\n' 'Error: recipes/core directory not found' || exit
    exit 1
}

for recipe_directory in glob('recipes/core/*') {
    let source_directory = "$recipe_directory/source"
    if ^test -d $source_directory && ^test -d "$source_directory/.git" {
        let recipe_name = "$(^basename $recipe_directory)"
        let repository_directory = "$(pwd)"
        cd $source_directory
        let commit_hash = "$(^git rev-parse HEAD)"
        let git_status = $status
        cd $repository_directory
        if !$git_status.ok {
            let git_code = status_code($git_status)
            exit $git_code
        }
        ^printf '%s: %s\n' $recipe_name $commit_hash || exit
    }
}
exit 0
