#!/bin/bash

SUDO_CMD=$(command -v sudo)

trap 'func_exit_handler $?' EXIT
# Overwrite other functions' exit to perform environment cleanup
function func_exit_handler()
{
    local exit_status=${1:-0}

    # call trace
    if [ "$exit_status" -ne 0 ] ; then
        dloge "Starting ${FUNCNAME[0]}(), exit status=$exit_status, FUNCNAME stack:"
        local i line_no

        for i in $(seq 1 $((${#FUNCNAME[@]}-1))); do

            line_no=${BASH_LINENO[$((i-1))]} || true
            # BASH_LINENO doesn't always work
            if [ $line_no -gt 1 ]; then line_no=":$line_no"; else line_no=""; fi

            dloge " ${FUNCNAME[i]}()  @  ${BASH_SOURCE[i]}${line_no}"
        done
    fi

    # when sof logger collect is open
    if [ "X$SOF_LOG_COLLECT" == "X1" ]; then
        # when error occurs, exit and catch etrace log
        [[ $exit_status -eq 1 ]] && {
            func_lib_start_log_collect 1
            sleep 1s
        }

        # There are bugs that cause DMA drops and the last few lines to
        # get stuck somewhere. This hack seems to be enough to nudge the
        # system and force it to DMA a bit more logs: hopefully all the
        # logs relevant to the current test.
        # See DMA issue https://github.com/thesofproject/sof/issues/4333
        # We must use a component that is available everywhere: pga
        local ldcf; ldcf=$(find_ldc_file)
        for i in 1 2; do
            # Running this twice makes it very easy to observe the stuck
            # lines bug: the "ipc" logs corresponding to this -F command
            # will appear _only once_ at the end of the slogger.txt DMA
            # trace!
            sudo "$SOFLOGGER" -l "${ldcf}" -F info=pga -i /dev/null -o /dev/null ||
                test "$exit_status" -ne 0 || exit_status=1
        done
        # We _also_ need to wait for the trace_work() thread to run;
        # BOTH are needed. The bug is not just a delay.
        sleep 1

        local loggerBin wcLog; loggerBin=$(basename "$SOFLOGGER")
        # We need this to avoid the confusion of a "Terminated" message
        # without context.
        dlogi "pkill -TERM $loggerBin"
        sudo pkill -TERM "$loggerBin" || {
            dloge "sof-logger was already dead"
            exit_status=1
        }
        sleep 1s
        if pgrep "$loggerBin"; then
            dloge "$loggerBin resisted pkill -TERM, using -KILL"
            sudo pkill -KILL "$loggerBin"
            exit_status=1
        fi

        # $logfile is defined in a different file (lib.sh)
        # shellcheck disable=SC2154
        if test -e "$logfile"; then

            wcLog=$(wc -l "$logfile") # show both line count and filename
            dlogi "nlines=$wcLog"

            local nlines; nlines=$(wc -l < "$logfile") # line count only
            # The first line is the sof-logger header
            if [ "$nlines" -le 1 ]; then
                dloge "Empty logger trace"
                exit_status=1
            fi
        else
            dloge "Log file not found: $logfile"
            exit_status=1
        fi

    fi

    if [[ "$KERNEL_CHECKPOINT" =~ ^[0-9]{10} ]]; then
        journalctl_cmd --since=@"$KERNEL_CHECKPOINT" > "$LOG_ROOT/dmesg.txt"
    elif [[ "$KERNEL_CHECKPOINT" == "disabled" ]]; then
        journalctl_cmd > "$LOG_ROOT/dmesg.txt"
    else
       dloge 'Kernel check point "KERNEL_CHECKPOINT" is not properly set'
       dloge "KERNEL_CHECKPOINT=$KERNEL_CHECKPOINT"
       test "$exit_status" -ne 0 || exit_status=1
    fi
    # After log collected, KERNEL_CHECKPOINT will not be used any more
    unset KERNEL_CHECKPOINT

    # get ps command result as list
    local -a cmd_lst
    # $$ as current script pid
    # NOTICE: already test with $BASHPID:
    # it can output the same result of $$
    # but the result could not be stored in the array
    readarray -t cmd_lst < <(pgrep -P $$ -a|grep -v "$SCRIPT_NAME")
    # now force kill target process which maybe block the script quit
    if [ ${#cmd_lst[@]} -gt 0 ]; then
        local line
        dlogw "Process(es) started by $SCRIPT_NAME are still active, killing these process(es):"
        for line in "${cmd_lst[@]}"
        do
            dlogw "Catch pid: $line"
            dlogw "Kill cmd:'${line#* }' by kill -9"
            kill -9 "${line%% *}"
        done
    fi

    # check if function already defined.
    # on exit check whether pulseaudio is disabled.
    ret=0
    if [[ $(declare -f func_lib_restore_pulseaudio) ]]; then
        func_lib_restore_pulseaudio || ret=$?
    fi
    # if failed to restore pulseaudio, even if test case passed, set exit status
    # to ret to make test case failed. this helps to dectect pulseaudio failures.
    if [ "$exit_status" -eq 0 ] && [ $ret -ne 0 ]; then
        exit_status=$ret
    fi

    # We must always print some 'Test Result' otherwise some callers
    # will time out. These strings must match (at least) Jenkins'
    # expectations, see internal sof-framework/clsTestCase.py
    case $exit_status in
        0)
            dlogi "Test Result: PASS!"
        ;;
        1)
            dlogi "Test Result: FAIL!"
        ;;
        2)
            dlogi "Test Result: SKIP!"
        ;;
        *)
            dlogi "Unknown exit code: $exit_status"
            dlogi "Test Result: FAIL!"
        ;;
    esac

    builtin exit $exit_status
}

SUDO_LEVEL=""
# overwrite the sudo command, sudo in the script can direct using sudo command
sudo()
{
    func_hijack_setup_sudo_level || true
    local cmd
    case $SUDO_LEVEL in
        '0')    cmd="$*" # as root
        ;;
        '1')    cmd="$SUDO_CMD env 'PATH=$PATH' $*" # sudo without passwd
        ;;
        '2')    cmd="echo '$SUDO_PASSWD' | $SUDO_CMD -S env 'PATH=$PATH' $*" # sudo need passwd
        ;;
        *)      # without sudo permission
            dlogw "Need root privilege to run $*"
            return 2
    esac
    eval "$cmd"
}

func_hijack_setup_sudo_level()
{
    [[ "$SUDO_LEVEL" ]] && return 0
    # root permission, don't need to check
    [[ $UID -eq 0 ]] && SUDO_LEVEL=0 && return 0

    # Test for either cached credentials or NOPASSWD
    if $SUDO_CMD --non-interactive true
    then
        SUDO_LEVEL=1 && return 0
    fi

    # check for sudo passwd
    if [[ "$SUDO_PASSWD" ]]; then
        [[ $(echo "$SUDO_PASSWD"|$SUDO_CMD -S id -u) -eq 0 ]] && SUDO_LEVEL=2 && return 0
    fi
    return 1
}
