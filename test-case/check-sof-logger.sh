#!/bin/bash

##
## Case Name: check-sof-logger
## Preconditions:
##    sof-logger installed in system path
##    ldc file is in /etc/sof/ or /lib/firmware
##
## Description:
##    Checks basic functionality of the sof-logger itself. Does not test
##    the firmware, i.e., does NOT fail when errors are found in the
##    logs.
##
## Case step:
##    1. check sof-logger in system
##    2. check ldc file in system
##    3. run sof-logger
## Expect result:
##    sof-logger produces some output and did not fail
##

set -e

TOPDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=case-lib/lib.sh
source "${TOPDIR}"/case-lib/lib.sh

func_opt_parse_option "$@"

# check sof-logger location
type -a sof-logger ||
    die "sof-logger Not Installed!"


# Checksum a list of files, one filename per stdin line.
# Whitespace-safe and shellcheck-approved.
md5list()
{
    while read -r; do md5sum "$REPLY"; done
}

# Recent Ubuntu versions symlink the entire /bin -> /usr/bin so we
# cannot just count the number of filenames we found. Count the
# number of different _checksums_ we found in PATH.
if type -a -p sof-logger | md5list | awk '{ print $1 }' |
        sort -u | tail -n +2 | grep -q . ; then
    dloge "There are different sof-logger in PATH on the system $(hostname)!"
    type -a -p sof-logger | md5list
    die "Not testing a random sof-logger version"
fi
loggerBin=$(type -p sof-logger)
dlogi "Found file: $(md5sum "$loggerBin" | awk '{print $2, $1;}')"

dlogi "Looking for ldc File ..."
ldcFile=$(find_ldc_file) || die ".ldc file not found!"

dlogi "Found file: $(md5sum "$ldcFile"|awk '{print $2, $1;}')"

# etrace shared memory mailbox, newer feature.
etrace_file=$LOG_ROOT/logger.etrace.txt
etrace_stderr_file=$LOG_ROOT/logger.etrace_stderr.txt

func_lib_check_sudo

run_loggers()
{
    # These filenames are kept for backward-compatibility
    # DMA trace
    local data_file=$LOG_ROOT/logger.data.txt
    # stderr
    local error_file=$LOG_ROOT/logger.error.txt

    local etrace_exit

    # This test is not really supposed to run while the DSP is busy at
    # the same time, so $data_file will hopefully not be long.
    local dma_collect_secs=2

    dlogi "Trying to get the DMA trace log with background sof-logger ..."
    dlogc \
    "sudo $loggerBin  -t -f 3 -l  $ldcFile  -o  $data_file  2>  $error_file  &"
    sudo timeout -k 3 "$dma_collect_secs"  \
         "$loggerBin" -t -f 3 -l "$ldcFile" \
         -o "$data_file" 2> "$error_file" & dmaPID=$!

    sleep "$dma_collect_secs"
    loggerStatus=0; wait "$dmaPID" || loggerStatus=$?

    # 124 is the normal timeout exit status
    test "$loggerStatus" -eq 124 || {
        cat "$error_file"
        die "timeout sof-logger returned unexpected: $loggerStatus"
    }

    if is_zephyr; then
        dlogi "Skipping etrace for now because it's totally different with Zephyr"
        return 0
    fi

    dlogi "Trying to get the etrace mailbox ..."
    dlogc \
    "sudo $loggerBin    -f 3 -l  $ldcFile  2>  $etrace_stderr_file  -o  $etrace_file"
    sudo "$loggerBin"   -f 3 -l "$ldcFile" 2> "$etrace_stderr_file" -o "$etrace_file" || {
        etrace_exit=$?
        cat "$etrace_stderr_file" >&2
    }

    printf '\n'

    return $etrace_exit
}


dma_nudge()
{
    sudo timeout -k 5 2  "$loggerBin" -l "${ldcFile}" -F info=pga -t
}

# Dumps all logs before exiting
print_logs_exit()
{
    local exit_code="$1" errmsg="$2"

    # Print $errmsg twice: - once _after_ the (possibly long) logs
    # because the end is where everyone logically looks atfirst when the
    # test fails, and; - also now _before_ the logs in case something
    # goes wrong and we don't make it until the end.
    test -z "$errmsg" || dloge "$errmsg"

    local bname
    for ftype in "${stdout_files[@]}" "${stderr_files[@]}"; do
        printf '\n'
        bname="logger.$ftype.txt"
        dlogi "Log file $bname BEG::"
        cat "$LOG_ROOT/$bname" || true # we already checked these
        dlogi "::END log file $bname"
        printf '\n'
    done
    test -z "$errmsg" || dloge "$errmsg"
    exit "$exit_code"
}

reload_drivers()
{
    "${TOPDIR}"/tools/kmod/sof_remove.sh

    setup_kernel_check_point

    "${TOPDIR}"/tools/kmod/sof_insert.sh

    # The DSP may unfortunately need multiple retries to boot, see
    # https://github.com/thesofproject/sof/issues/3395
    dlogi "Waiting a few seconds for the DSP to fully boot and then suspend"
    for i in $(seq 1 5); do
        if sudo test -e /sys/kernel/debug/sof/etrace; then break; fi
        sleep 1
    done
    # Now give enough time to go to D3 suspend
    sleep 4
}

main()
{
    if is_zephyr; then
        # Keeping these confusing DMA names because they're used in
        # several other places.
        stdout_files=(data)
        stderr_files=(error)
    else
        stdout_files=(data  etrace)
        stderr_files=(error etrace_stderr)
    fi

    reload_drivers

    run_loggers

    local f

    for f in "${stderr_files[@]}"; do
        local stderr_file="$LOG_ROOT/logger.$f.txt"
        test -e "$stderr_file" || die "$stderr_file" not found
        if test -s "$stderr_file"; then
            print_logs_exit 1 "stderr $stderr_file is not empty"
        fi
        printf 'GOOD: %s was empty, no stderr output from that sof-logger instance\n' \
               logger."$f".txt > "$stderr_file"
    done

    # Simulates a stuck DMA to test the code below
    # sed -i -e '2,$ d' "$LOG_ROOT/logger.data.txt"

    # Search for the log header, should be something like this:
    # TIMESTAMP  DELTA C# COMPONENT  LOCATION  CONTENT
    # then for the 'FW ABI' banner
    for f in "${stdout_files[@]}"; do
        local tracef="$LOG_ROOT/logger.$f.txt"
        test -e "$tracef" || die "$tracef" not found
        # Other columns are optional
        head -n 1 "$tracef" | grep -q 'COMPONENT.*CONTENT'  ||
            print_logs_exit 1 "Log header not found in ${tracef}"

        # See initial message SOF PR #3281 / SOF commit 67a0a69
        grep -q 'dma-trace.c.*FW ABI.*tag.*hash' "$tracef" || {

            # Workaround for DMA trace bug
            # https://github.com/thesofproject/sof/issues/4333
#            if [ "$f" = data ]; then
            if false; then # let's check whether #4333 was finally fixed by #4763
                dloge "Empty or stuck DMA trace? Let's try to nudge it."
                dloge '  vv  Workaround for SOF issue 4333  vv'
                local second_chance="$LOG_ROOT/logger.dma_trace_bug_4333.txt"
                dma_nudge | tee "$second_chance"
                printf '\n'
                dloge ' ^^ End of workaround nudge for 4333 ^^ '
                printf '\n'

                if head "$second_chance" |
                        grep -q 'dma-trace.c.*FW ABI.*tag.*hash'; then
                    continue # and don't report failure 4333
                fi
            fi

            print_logs_exit 1 "Initial FW ABI banner not found in ${tracef}"
        }
    done

    # Show all outputs even when everything went OK
    print_logs_exit 0
}

main "$@"
