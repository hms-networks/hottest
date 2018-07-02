add_required_host_executables flock

function acquire_lock() {
    # Creates a lock with a given name. If it is not available it waits for
    # timeout_sec seconds (can be 0).
    #
    # Be aware that this function only keeps the lock alive for as long as the
    # current process is alive. E.g. 'bash -c "acquire_lock TAG"'' or
    # '$(acquire_lock TAG)' will return with the lock already unlocked.
    #
    # In this framework steps(functions) are run through the "timeout" util,
    # which spawns a subprocess. This means that the locks are only alive on
    # function scope, which is good.
    #
    # Notice that this type of lock doesn't stop the timeout of the test step,
    # use them only when:
    #
    # -The resource you are planning to use is always supposed to be locked
    #  briefly, so you don't start testing and then time out because a lot of
    #  time was consumed while waiting for the lock.
    #
    # -To bail out early from a test when someone else has taken the
    #  lock.
    #
    # The third parameter is the name of a file to store the locking FD. This is
    # only useful if you have to call release_lock.
    #
    # Examples:
    #
    # > acquire_lock TAG || { return 1; }
    #
    #   Tries to acquire the a lock with tag "TAG". Always returns inmediately.
    #   The lock is kept locked until the process dies.
    #
    # > acquire_lock TAG 10 || { return 1; }
    #
    #   Tries to acquire the a lock with tag "TAG". Tries to wait 10 second for
    #   the lock to be available in case it's used by another process. The lock
    #   is kept until the process dies.
    #
    # > acquire_lock TAG 10 ./lock-fd-file || { return 1; }
    # > .. code lock with the lock taken ...
    # > release_lock ./lock-fd-file
    #
    # Same as the above, but it manually releases the lock before the process
    # dies.
    #
    local tag=$1
    local timeout_sec=${2:-0}
    local fd_out_file=${3:-/dev/null}

    # Stores file descriptor number into the lock_fd variable (weird syntax).
    local lock_fd=""
    exec {lock_fd}>/tmp/${tag}.hottest.lock

    local timeout_arg="-w $timeout_sec"
    if [[ "$timeout_sec" -eq 0 ]]; then
        timeout_arg="-n"
    fi
    flock "$timeout_arg" "$lock_fd"
    if [[ "$?" -ne 0 ]]; then
        errcho "Unable to acquire_lock: $tag"
        return 1
    fi
    echo "$lock_fd" > $fd_out_file
}

function release_lock() {
    # See acquire_lock
    local lock_fd=$(cat $1)
    flock -u $lock_fd
}
