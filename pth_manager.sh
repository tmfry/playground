#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034

# ==============================================================================
# pth_manager Bash Module for Dynamic Venv Extension.
# Version: 0.0.1
# Author: Tom Fry (@tmfry)
# ==============================================================================

# ------------------------------------------------------------------------------
# Technical Overview:
# ------------------------------------------------------------------------------
# This module automatically manages Python's `sys.path` by injecting developer 
# directories into the active virtual environment using .pth files. It 
# integrates with `direnv` and overrides the `cd` command to manage path injection 
# and cleanup transparently during directory changes.
#
# Key features:
# - Automatic injection and cleanup of developer paths.
# - State management via environment variables independent of `direnv`'s core logic.
# - Caching of Python paths for fast performance (no repeated Python calls).
# - Safety checks for system directories and file permissions.
# - Support for nested projects via the `PTH_MANAGER_ROOT` contract.

# ------------------------------------------------------------------------------
# Compatibility:
# ------------------------------------------------------------------------------
# This script uses Bash-specific syntax (e.g., [[ ... ]], builtin `cd`) and 
# is designed primarily for GNU Bash environments where `cd` can be overridden.
#
# - Confirmed Shells: Bash (>= 4.x recommended)
# - Not compatible with: dash, standard POSIX sh, Zsh (requires different hook mechanism)

# ------------------------------------------------------------------------------
# Dependencies & Failure Modes:
# ------------------------------------------------------------------------------
# - Requires the `python` executable to be available in the system `PATH`.
# - Depends on `python` returning a valid, non-empty site-packages directory list.
# - Safety checks prevent modification of system directories (/usr/local/...).
# - If dependencies are not met, configuration is missing/permissions denied, 
#   the script will output a [BASH PM] WARNING/ERROR and exit gracefully 
#   (returning codes 1 or 2).

# ------------------------------------------------------------------------------
# Configuration Variables Expected:
# ------------------------------------------------------------------------------
# These variables must be set by the user (typically in .envrc or ~/.bashrc).
#
# - `PTH_MANAGER_ROOT`: [path string] Absolute path to the project root. A contract:
#                       its presence enables the module's logic exactly once upon entry
#                       into the project scope (and triggers cleanup on exit).
# - `SHOULD_INJECT_PTH_FILE`: [int|boolean string] The explicit flag that triggers
#                             the injection logic when set to 1 or "true".
# - `DEV_SITE_PACKAGES_DIR`: [path string] Absolute or relative path to the developer
#                            library directory to be added to `sys.path` via the .pth file.
# - `PTH_FILE_NAME`: [string] Name for the .pth file (e.g., 'dev_libs.pth').

# Optional:
# - `DEBUG`: [int|boolean string] Set to 1 or "true" to enable debug output.

# ------------------------------------------------------------------------------
# Internal State Variables Used (Managed by the module, do not modify manually):
# ------------------------------------------------------------------------------
# - `DIRENV_PTH_ACTION_DONE``: [int] Flag indicating an action was performed (1=done).
# - `DIRENV_PTH_ACTION_TYPE``: [string] Type of action performed ("CREATED_FILE" or "ADDED_LINE").
# - `BASH_PM_INJECTED_PATH``: [path string] The specific directory path where the .pth file was written.
# - `BASH_PM_IS_RUNNING_HOOK``: [int] Temporary flag to authorize internal function calls.
# - `BASH_PM_PYTHON_TARGET_PATH_CACHE``: [path string] Cached target path to avoid repeated Python calls.

# ------------------------------------------------------------------------------
# Usage:
#   1. Source this script into your main shell configuration (e.g., ~/.bashrc).
#   2. Configure required variables within your project's `.envrc` file to enable behavior 
#      and override the default `cd` command.
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# Function: _debug_echo <message parts...> (Internal Utility)
# Description: Output a debug message if the `DEBUG` flag is enabled. 
#              Join all provided arguments into a single output line.
#              Not intended for direct user invocation.
#
# Arguments:
#   <message parts...> - [string] One or more strings that make up the message.
#
# Output:
#   Echos the formatted debug message to standard output (stdout) if `DEBUG` is active.
#   Echos informational messages to stdout if called incorrectly.
#
# Returns:
#   0 - Success (message processed or skipped due to flag).
#   2 - Invoked incorrectly by user (via direct call, not via hook).
# ------------------------------------------------------------------------------
_debug_echo() {
    # Protection against direct user invocation.
    if [[ "${BASH_PM_IS_RUNNING_HOOK:-0}" -ne 1 ]]; then
        echo "[BASH PM] INFO: '_debug_echo' is an internal utility function and should not be called directly."
        return 2 # Function used incorrectly
    fi

    # debug_lower=$(echo "$DEBUG" | tr '[:upper:]' '[:lower:]')
    if [[ "${DEBUG}" == '1' ]] || [[ "${DEBUG}" == "true" ]]; then
        local message="$*"
        echo "[BASH PM DEBUG] $message"
    fi

    return 0
}


# ------------------------------------------------------------------------------
# Function: _is_system_path <path> (Internal Utility)
# Description: Check if the given path is likely a system-owned Python directory 
#              (e.g., in `/usr/local/lib/python*` or `/usr/lib/python*`).
#              Not intended for direct user invocation.
#
# Arguments:
#   <path> - [path string] The absolute path to check.
#
# Output:
#   Echos informational messages to standard output (stdout) if called incorrectly.
#
# Returns:
#   0 - True (the path IS a system path).
#   1 - False (the path IS NOT a system path).
#   2 - Invoked incorrectly by user (via direct call, not via hook).
# ------------------------------------------------------------------------------
_is_system_path() {
    # Protection against direct user invocation.
    if [[ "${BASH_PM_IS_RUNNING_HOOK:-0}" -ne 1 ]]; then
        echo "[BASH PM] INFO: '_is_system_path' is an internal utility function and should not be called directly.."
        return 2 # Function used incorrectly
    fi

    local path=$1
    # Check for standard system prefixes (adjust as needed for specific systems)
    if [[ "$path" == "/usr/local/lib/python"* ]] || [[ "$path" == "/usr/lib/python"* ]]; then
        return 0 # True (is a system path)
    else
        return 1 # False (is not a system path)
    fi
}


# ------------------------------------------------------------------------------
# Function: _get_python_site_packages_path (Internal Utility)
# Description: Dynamically determine the site-packages path using Python and cache it.
#              Extract only the first path found in Python's `site.getsitepackages()` list.
#              Not intended for direct user invocation.
#
# Output:
#   Echos the calculated absolute path string to standard output (stdout) on success.
#   Echos warning/error messages to standard error (stderr) on failure.
#
# Returns:
#   0 - Success (path determined and echoed).
#   1 - Failure (path could not be determined, e.g., Python command failed).
#   2 - Invoked incorrectly by user (via direct call, not via hook).
# ------------------------------------------------------------------------------
_get_python_site_packages_path() {
    # Protection against direct user invocation.
    if [[ "${BASH_PM_IS_RUNNING_HOOK:-0}" -ne 1 ]]; then
        echo "[BASH PM] INFO: '_get_python_site_packages_path' is an internal utility function and should not be called directly."
        return 2 # Function used incorrectly
    fi

    # If the path is already cached in the environment variable, return it immediately.
    if [[ -n "${BASH_PM_PYTHON_TARGET_PATH_CACHE}" ]]; then
        echo "${BASH_PM_PYTHON_TARGET_PATH_CACHE}"
        return 0
    fi

    # Execute the heavy Python command only if not cached.
    local target_path
    target_path=$(python -c "import site; print(site.getsitepackages())" | cut -d"'" -f2)

    if [[ -z "$target_path" ]]; then
        echo "[BASH PM] WARNING: Python returned an empty list. Cannot determine path." >&2
        return 1
    fi

    # Cache the result in an environment variable for subsequent calls in this session.
    export BASH_PM_PYTHON_TARGET_PATH_CACHE="$target_path"
    echo "$target_path"
    return 0
}


# ------------------------------------------------------------------------------
# Function: _manage_pth (Internal Utility)
# Description: Orchestrate the main logic of the PTH Manager module. 
#              Check current project scope using the `PTH_MANAGER_ROOT` contract 
#              and perform idempotent cleanup or injection of developer paths.
#              Not intended for direct user invocation; triggered by the `cd` override.
#
# Output:
#   Echos status, warning, error, and debug messages to stdout/stderr.
#
# Returns:
#   0 - Success (action completed, skipped, or cleanup done).
#   1 - Critical Error (permission denied during file write/deletion).
#   2 - Invoked incorrectly by user (via direct call, not via hook).
# ------------------------------------------------------------------------------
_manage_pth() {
    # Protection against direct user invocation.
    if [[ "${BASH_PM_IS_RUNNING_HOOK:-0}" -ne 1 ]]; then
        echo "[BASH PM] INFO: '_manage_pth_action' is an internal function of the PTH Manager module."
        echo "[BASH PM] INFO: It runs automatically when you use the 'cd' command."
        return 2
    fi
    _debug_echo "Function _manage_pth called after cd."

    # Load and declare local variables from the environment
    # PTH_MANAGER_TOOT is the primary contract flag
    local project_root_contract="${PTH_MANAGER_ROOT}"
    # shellcheck disable=SC2153
    local dev_lib_path="${DEV_SITE_PACKAGES_DIR}"
    # shellcheck disable=SC2153
    local pth_file_name="${PTH_FILE_NAME}"
    local action_done="${DIRENV_PTH_ACTION_DONE:-0}"
    local action_type="${DIRENV_PTH_ACTION_TYPE}"
    local injected_target_path="${BASH_PM_INJECTED_PATH}"

    local target_packages_dir
    local full_pth_file

    # --- Step 1: Check and execute cleanup logic (Cleanup Check) ---
    # Condition: Action was performed AND we are outside the project root defined by contract.
    if [[ "$action_done" -eq 1 ]] && [[ -n "$project_root_contract" ]] && [[ "$PWD"/ != "$project_root_contract"/* ]]; then
        _debug_echo "Cleanup required: action done AND PWD is outside of project root contract."

        if [[ -n "$injected_target_path" ]]; then
            full_pth_file="$injected_target_path/$pth_file_name"

            if [[ "$action_type" == "CREATED_FILE" ]]; then
                if [[ -f "$full_pth_file" ]]; then
                    rm -f "$full_pth_file"
                    if [[ ! -f "$full_pth_file" ]]; then
                        _debug_echo "[BASH PM] CLEANUP: Removed temporary .pth file."
                    else
                        echo "[BASH PM] WARNING: Failed to verify removal of $full_pth_file. Check permissions."
                    fi
                else
                    _debug_echo "File $full_pth_file not found during cleanup, assumed already removed."
                fi
            elif [[ "$action_type" == "ADDED_LINE" ]]; then
                if [[ -f "$full_pth_file" ]]; then
                    if grep -vF "$dev_lib_path" "$full_pth_file" > "$full_pth_file.tmp" && mv "$full_pth_file.tmp" "$full_pth_file"; then
                        _debug_echo "[BASH PM] CLEANUP: Removed the specific path from the PTH file."
                    else
                        echo "[BASH PM] WARNING: Failed to update $full_pth_file during cleanup. Check permissions."
                    fi
                else
                    _debug_echo "File $full_pth_file not found during cleanup."
                fi
            fi
        else
            echo "[BASH PM] WARNING: Injected path variable BASH_PM_INJECTED_PATH was missing during cleanup."
        fi

        # Unset state flags after attempted cleanup
        unset DIRENV_PTH_ACTION_DONE
        unset DIRENV_PTH_ACTION_TYPE
        unset BASH_PM_INJECTED_PATH
        unset BASH_PM_PYTHON_TARGET_PATH_CACHE
        # NOTE: PTH_MANAGER_ROOT and other config are left to direnv to unset
        return 0
    fi

    # --- Step 2: Check and execute injection logic (Injection Check) ---
    # Condition: If the contract is set AND the action hasn't been done yet in this session.
    if [[ -n "$project_root_contract" ]] && [[ "$action_done" -ne 1 ]]; then
        _debug_echo "Injection required: contract is set, action not done."

        # Get target directory path using the new caching helper
        if ! target_packages_dir=$(_get_python_site_packages_path); then
           # _get_python_site_packages_path already printed a warning
           return 0
        fi

        # Safety Check: Avoid writing to system directories (/usr/local/...)
        if _is_system_path "$target_packages_dir"; then
            echo "[BASH PM] WARNING: Target path is a system directory ($target_packages_dir). Injection aborted."
            return 0
        fi

        full_pth_file="$target_packages_dir/$pth_file_name"

        # Check existence of source/target directories before writing the file
        if [[ ! -d "$dev_lib_path" ]] || [[ ! -d "$target_packages_dir" ]]; then
            echo "[BASH PM] WARNING: Required directories not found. Cannot inject path."
            return 0
        fi

        # Idempotent logic for creating/appending the file with post-check
        if [[ ! -f "$full_pth_file" ]]; then
            if echo "$dev_lib_path" > "$full_pth_file"; then
                export DIRENV_PTH_ACTION_DONE=1
                export DIRENV_PTH_ACTION_TYPE="CREATED_FILE"
                export BASH_PM_INJECTED_PATH="$target_packages_dir"
                echo "[BASH PM] SUCCESS: Created PTH file. Venv extended."
            else
                echo "[BASH PM] CRITICAL ERROR: Permission denied when writing to $full_pth_file. Check directory permissions."
                return 1
            fi
        elif ! grep -qF "$dev_lib_path" "$full_pth_file"; then
            if echo "$dev_lib_path" | tee -a "$full_pth_file" > /dev/null; then
                export DIRENV_PTH_ACTION_DONE=1
                export DIRENV_PTH_ACTION_TYPE="ADDED_LINE"
                export BASH_PM_INJECTED_PATH="$target_packages_dir"
                echo "[BASH PM] SUCCESS: Appended path to PTH file."
            else
                echo "[BASH PM] CRITICAL ERROR: Permission denied when appending to $full_pth_file. Check directory permissions."
                return 1
            fi
        else
            _debug_echo "File already exists and contains path. No action needed."
        fi
        return 0
    fi

    _debug_echo "No action required for current state."
}


# ------------------------------------------------------------------------------
# Function: cd <directory> (Override & Hook)
# Description: Override the default shell 'cd' command. Change the directory
#              using `builtin cd`, and if successful, conditionally triggers 
#              the `pth_manager` logic via `_manage_pth` based on configuration flags.
#
# Arguments:
#   <directory> - [path string] The target directory to change to.
#
# Output:
#   Inherits output/errors from the original `builtin cd`.
#   Echos debug information via `_debug_echo` if the `DEBUG` flag is set.
#
# Returns:
#   0             - Success (directory changed and logic executed/skipped).
#   Non-zero exit - Failure (error codes inherited directly from `builtin cd`; 
#                   e.g., 1 or 2 for common failures).
# ------------------------------------------------------------------------------
cd() {
    _debug_echo "CD wrapper called."

    builtin cd "$@"
    local cd_status=$?

    if [[ $cd_status -ne 0 ]]; then
        _debug_echo "Builtin cd failed with status $cd_status. Aborting. "
        return $cd_status
    fi

    if [[ "$SHOULD_INJECT_PTH_FILE" == '1' ]] || [[ "$SHOULD_INJECT_PTH_FILE" == 'true' ]]; then
        _debug_echo "Injection trigger is active. Calling _manage_pth."

        # Set a temporary flag indicating that the internal functions are being called correctly
        export BASH_PM_IS_RUNNING_HOOK=1
        _manage_pth
        # Unset the temporary flag after execution
        unset BASH_PM_IS_RUNNING_HOOK
    fi
}


# ==============================================================================
# USER ACTIONS REQUIRED (INTEGRATION GUIDE)
# ==============================================================================
#
# 1. Add the following lines to your ~/.bashrc file:
# --------------------------------------------------
# if [[ -f ~/bin/pth_manager.sh ]]; then
#     source ~/bin/pth_manager.sh
#     # export SHOULD_INJECT_PTH_FILE=1
#     # export DEV_SITE_PACKAGES_DIR="path/to/dev/site-packages"
#     # export PTH_FILE_NAME="dev_libs.pth"
# fi
# --------------------------------------------------
#
# 2. Add the following lines to your project's .envrc file:
# --------------------------------------------------
# # Enable the Python Path Manager functionality
# export SHOULD_INJECT_PTH_FILE=1
# export PTH_MANAGER_ROOT="$PWD"
# 
# # Execute the manager logic immediately upon direnv load/allow
# if [[ -f ~/bin/pth_manager.sh ]]; then
#     source ~/bin/pth_manager.sh
#     export BASH_PM_IS_RUNNING_HOOK=1
#     _manage_pth
#     unset BASH_PM_IS_RUNNING_HOOK
# fi

# ==============================================================================
# FOOTER / TECHNICAL DEBT NOTES
# ==============================================================================
#
# FIXME/DRY: The logic for determining 'target_packages_dir' and the file creation/appending
#            logic is highly repetitive. This should be abstracted into cleaner, dedicated
#            helper functions (_get_target_path, _write_pth_file) with robust error handling.
#
# TODO: The current system path check (_is_system_path) only covers /usr/local and /usr/lib.
#       This may need expansion for compatibility with other niche Linux distributions.
#
# NOTE/ISSUE: The current state management relies on environment variables (DIRENV_PTH_ACTION_DONE, etc.)
#             which are unset by direnv when transitioning between directories managed by different .envrc files.
#             This causes cleanup logic to fail prematurely if a project has a nested .envrc file.
#
# TODO/FIXME: The state management should be migrated to a disk-based flag file (e.g., ~/.bash_pm_state)
#             to ensure persistence across directory changes and independence from direnv's environment management.
#             This is the only robust solution for nested projects.
#
# TODO/FEATURE: Consider supporting the injection of multiple paths (multi-environment capability)
#               instead of the current single DEV_SITE_PACKAGES_DIR variable.
#               This would require changing the input format (e.g., an array or a file).
#
# TODO: Explore using 'trap EXIT' in addition to the 'cd' override for guaranteed cleanup
#       when the terminal session is closed unexpectedly (though more complex to implement).
