#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034

# ==============================================================================
# pth_manager Bash Module for Dynamic Venv Extension.
# Version: 0.0.1
# Author: Tom Fry (@tmfry)
# ==============================================================================

# ------------------------------------------------------------------------------
# Technical Overview
# ------------------------------------------------------------------------------
# This module automatically manages Python's `sys.path` by injecting developer 
# directories into the active virtual environment using .pth files. It 
# integrates with `direnv` and overrides the `cd` command to manage path 
# injection and cleanup transparently during directory changes.
#
# Key features:
# - Automatic, idempotent injection and cleanup of developer paths.
# - State management via environment variables independent of direnv's core logic.
# - Robust authorization using the Bash call stack (FUNCNAME), eliminating reliance on flags/tokens.
# - Caching of Python paths for performance (avoids repeated Python calls).
# - Safety checks for system directories and file permissions.
#
# ------------------------------------------------------------------------------
# Compatibility
# ------------------------------------------------------------------------------
# This script uses Bash-specific syntax (e.g., [[ ... ]], FUNCNAME, builtin `cd`) 
# and is designed primarily for GNU Bash environments.
#
# - Confirmed Shells: Bash (>= 4.x recommended)
# - Not compatible with: dash, standard POSIX sh, Zsh 
#
# ------------------------------------------------------------------------------
# Dependencies & Failure Modes
# ------------------------------------------------------------------------------
# - Requires the `python` executable to be available in the system `PATH`.
# - Depends on `python` returning a valid, non-empty site-packages directory list.
# - Fails gracefully (returning code 1 for critical failure or code 2 for incorrect invocation context).
#
# ------------------------------------------------------------------------------
# Configuration Variables Expected (Set by user in .envrc or ~/.bashrc)
# ------------------------------------------------------------------------------
# - `PTH_MANAGER_ROOT`: [path string] Absolute path to the project root (contract flag).
# - `SHOULD_INJECT_PTH_FILE`: [int|boolean string] Explicit flag (1 or "true") that triggers injection logic.
# - `DEV_SITE_PACKAGES_DIR`: [path string] Path to the developer library directory to be added to `sys.path`.
# - `PTH_FILE_NAME`: [string] Name for the .pth file (e.g., 'dev_libs.pth').
#
# Optional:
# - `DEBUG`: [int|boolean string] Set to 1 or "true" to enable debug output via _debug_echo.
#
# ------------------------------------------------------------------------------
# Internal State Variables Used (Managed by the module)
# ------------------------------------------------------------------------------
# - `DIRENV_PTH_ACTION_DONE`: [int] Flag indicating an action was performed (1=done).
# - `DIRENV_PTH_ACTION_TYPE`: [string] Type of action ("CREATED_FILE" or "ADDED_LINE").
# - `BASH_PM_INJECTED_PATH`: [path string] The directory path where the .pth file was written.
# - `BASH_PM_PYTHON_TARGET_PATH_CACHE`: [path string] Cached target path to avoid repeated Python calls.
#
# ------------------------------------------------------------------------------
# Usage Summary
# ------------------------------------------------------------------------------
# 1. Source this script into your main shell configuration (e.g., ~/.bashrc).
# 2. Configure variables in your project's `.envrc` file and run `direnv allow`.
# 3. Use `cd` as usual; the hook manages the .pth file transparently.
# 4. Use public functions `check_pth_manager` and `please_manage_pth` for status/manual triggers.
# ------------------------------------------------------------------------------


# --- Internal utility functions ---


# ------------------------------------------------------------------------------
# Function: _is_caller_authorized (Internal Utility)
# Description: Checks if the immediate calling function is within the authorized
#              whitelist, using Bash's FUNCNAME array for stack introspection.
#
# Arguments:
#   None
#
# Output:
#   Echos an error message to stderr if the caller is not in the whitelist.
#
# Returns:
#   0 - True (the caller is authorized).
#   1 - False (the caller is not authorized/failure to authorize).
# ------------------------------------------------------------------------------
_is_caller_authorized() {
    local AUTHORIZED_CALLERS=(
        # Public API functions
        cd
        please_manage_pth
        # Internal utility functions
        _cleanup_pth
        _debug_echo
        _is_python_system_path
        _get_python_site_packages_path
        _manage_pth
    )

    # Get the name of the function that called the current function.
    local caller="${FUNCNAME[1]}"

    for authorized in "${AUTHORIZED_CALLERS[@]}"; do
        if [[ "${caller}" == "${authorized}" ]]; then
            return 0
        fi
    done

    echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally. Unauthorized caller: '${caller}'." >&2
    # echo "[BASH PM] ERROR: Authorization failed for caller: ${caller}" >&2
    return 1
}


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
#   2 - Incorrect invocation context.
# ------------------------------------------------------------------------------
_debug_echo() {
    if ! _is_caller_authorized; then
        echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally." >&2
        return 2
    fi

    # debug_lower=$(echo "$DEBUG" | tr '[:upper:]' '[:lower:]')
    if [[ "${DEBUG}" == '1' ]] || [[ "${DEBUG}" == "true" ]]; then
        local full_message="$*"
        echo "[BASH PM DEBUG] ${full_message}"
    fi

    return 0
}


# ------------------------------------------------------------------------------
# Function: _is_python_system_path <path> (Internal Utility)
# Description: Check if the provided path is likely a system-owned Python directory 
#              (e.g., in /usr/local/lib/python* or /usr/lib/python*).
#
# Arguments:
#   <path> - [path string] The absolute path to check.
#
# Output:
#   None (uses internal `_debug_echo` if needed).
#
# Returns:
#   0 - True (the path is a system path).
#   1 - False (the path is not a system path).
#   2 - Incorrect invocation context.
# ------------------------------------------------------------------------------
_is_python_system_path() {
    if ! _is_caller_authorized; then
        echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally." >&2
        return 2
    fi

    local path="${1}"
    # Check for standard system prefixes (adjust as needed for specific systems)
    if [[ "${path}" == "/usr/local/lib/python"* ]] || [[ "${path}" == "/usr/lib/python"* ]]; then
        return 0
    else
        return 1
    fi
}


# ------------------------------------------------------------------------------
# Function: _get_python_site_packages_path (Internal Utility)
# Description: Dynamically determine the site-packages path using Python and cache it.
#              Extract the first valid path found in Python's `site.getsitepackages()`.
#
# Arguments:
#   None.
#
# Output:
#   Echos the calculated absolute path string to standard output (stdout) on success.
#   Echos warning/error messages to standard error (stderr) on failure.
#
# Returns:
#   0 - Success (path determined and echoed).
#   1 - Failure (e.g., `python` not found in PATH, empty list returned, command failed).
#   2 - Incorrect invocation context.
# ------------------------------------------------------------------------------
_get_python_site_packages_path() {
    if ! _is_caller_authorized; then
        echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally." >&2
        return 2
    fi

    # If the path is already cached, return it immediately.
    if [[ -n "${BASH_PM_PYTHON_TARGET_PATH_CACHE}" ]]; then
        echo "${BASH_PM_PYTHON_TARGET_PATH_CACHE}"
        return 0
    fi

    if ! command -v python &> /dev/null; then
        echo "[BASH PM] ERROR: 'python' executable not found in PATH. Is the Venv active?" >&2
        return 1
    fi

    # Execute the heavy Python command only if not cached.
    local target_path
    target_path=$(python -c "import site; print(site.getsitepackages())" | cut -d"'" -f2)

    if [[ -z "${target_path}" ]]; then
        echo "[BASH PM] WARNING: Python returned an empty list. Cannot determine target path." >&2
        return 1
    fi

    # Cache the result in an environment variable for subsequent calls in this session.
    export BASH_PM_PYTHON_TARGET_PATH_CACHE="${target_path}"
    echo "${target_path}"
    return 0
}


# ------------------------------------------------------------------------------
# Function: _cleanup_pth <target_dir> <file_name> (Internal Utility)
# Description: Remove the specified .pth file from the target directory and unset
#              related environment variables. This cleans up after the module.
#
# Arguments:
#   <target_dir> - [path string] The directory containing the .pth file.
#   <file_name> - [string] The name of the .pth file.
#
# Output:
#   Echos informational messages to standard output (stdout).
#   Echos warning/error messages to standard error (stderr) on failure.
#
# Returns:
#   0 - Success (file removed or already absent).
#   1 - Failure (e.g., permission denied during file removal).
#   2 - Incorrect invocation context.
# ------------------------------------------------------------------------------
_cleanup_pth() {
    # Check authorization via call stack. Must be called internally.
    if ! _is_caller_authorized; then
        echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally." >&2
        return 2
    fi

    local target_dir="${1}"
    local file_name="${2}"
    local pth_file_path="${target_dir}/${file_name}"

    _debug_echo "Attempting to clean up PTH file: ${pth_file_path}"

    if [[ -f "${pth_file_path}" ]]; then
        if rm "${pth_file_path}"; then
            echo "[BASH PM] SUCCESS: Removed stale PTH file: ${pth_file_path}"
            # Unset state variables upon successful cleanup
            unset DIRENV_PTH_ACTION_DONE
            unset DIRENV_PTH_ACTION_TYPE
            unset BASH_PM_INJECTED_PATH
            unset BASH_PM_PYTHON_TARGET_PATH_CACHE
        else
            echo "[BASH PM] ERROR: Failed to remove PTH file at ${pth_file_path}. Check permissions." >&2
            return 1
        fi
    else
        _debug_echo "PTH file not found during cleanup: ${pth_file_path} (Already clean)"
    fi
    return 0
}


# ------------------------------------------------------------------------------
# Function: _check_nested_envrcs (Internal Utility)
# Description: Checks for nested .envrc files within the project root using `find`.
#              Issues a loud warning to stderr if detected, as this configuration
#              causes state management issues with the current architecture.
#
# Arguments:
#   None. (Uses the exported `PTH_MANAGER_ROOT` variable).
#
# Output:
#   Echos a loud warning message to stderr if a nested .envrc is found.
#
# Returns:
#   0 - Success (check completed, regardless of finding a file).
# ------------------------------------------------------------------------------
_check_nested_envrcs() {
    # This is a dirty check using find, as robust state management
    # for nested projects is not implemented in the current version.
    local project_root="${PTH_MANAGER_ROOT:-}"

    if [[ -n "${project_root}" ]] && [[ -d "${project_root}" ]]; then
        # Use a subshell to avoid changing the current directory
        if find "${project_root}" -mindepth 2 -name ".envrc" -print -quit | grep -q ".envrc"; then
            echo "[BASH PM] !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "[BASH PM] WARNING: NESTED .envrc FILE DETECTED" >&2
            echo "[BASH PM] The current module architecture has known issues with nested projects." >&2
            echo "[BASH PM] State management may fail unexpectedly. See TECHNICAL DEBT for details." >&2
            echo "[BASH PM] !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        fi
    fi
}


# ------------------------------------------------------------------------------
# Function: _manage_pth (Internal Utility)
# Description: Orchestrate the core injection/cleanup logic. Check project scope
#              using the `PTH_MANAGER_ROOT` contract  and idempotently manage
#              developer paths.
#
# Arguments:
#   None.
#
# Output:
#   Echos status, warning, error, and debug messages to stdout/stderr.
#
# Returns:
#   0 - Success (action completed, skipped, or cleaned up).
#   1 - Critical Error (permission denied, missing config/dependencies).
#   2 - Incorrect invocation context.
# ------------------------------------------------------------------------------
_manage_pth() {
    # Check: If FUNCNAME[1] is empty, this is a direct terminal call.
    # Use please_manage_pth or cd override for authorized execution.
    if [[ -z "${FUNCNAME[0]}" ]]; then
        echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally." >&2
        check_pth_manager
        return 2
    fi

    if ! _is_caller_authorized; then
        echo "[BASH PM] ERROR: '${FUNCNAME[0]}' must be called internally." >&2
        echo "[BASH PM] Use check_pth_manager for info or please_manage_pth from '.envrc'." >&2
        return 2
    fi

    _debug_echo "Function '${FUNCNAME[0]}' called."

    # Execute the dirty check right away if we are sourcing the script within a project scope
    _check_nested_envrcs

    # Load and declare local variables from the environment.
    # PTH_MANAGER_TOOT is the primary contract flag.
    local project_root_contract="${PTH_MANAGER_ROOT}"
    # shellcheck disable=SC2153
    local dev_lib_path="${DEV_SITE_PACKAGES_DIR}"
    # shellcheck disable=SC2153
    local pth_file_name="${PTH_FILE_NAME}"

    # Internal state variables.
    local action_done="${DIRENV_PTH_ACTION_DONE:-0}"
    local action_type="${DIRENV_PTH_ACTION_TYPE}"
    local injected_target_path="${BASH_PM_INJECTED_PATH}"

    local target_packages_dir
    local full_pth_file

    # --- Step 1: Check and execute cleanup logic (Cleanup Check) ---
    # Condition: Action was performed AND we are outside the project root defined by contract.
    if [[ "${action_done}" -eq 1 ]] && [[ -n "${project_root_contract}" ]] && [[ "${PWD}"/ != "${project_root_contract}"/* ]]; then
        _debug_echo "Cleanup required: action done AND PWD is outside of project root contract."

        if [[ -n "${injected_target_path}" ]]; then
            full_pth_file="${injected_target_path}/${pth_file_name}"
            _cleanup_pth "${injected_target_path}" "${pth_file_name}"
        else
            echo "[BASH PM] WARNING: Injected path variable BASH_PM_INJECTED_PATH was missing during cleanup." >&2
        fi
        # Unset state flags after attempted cleanup
        unset DIRENV_PTH_ACTION_DONE
        unset DIRENV_PTH_ACTION_TYPE
        unset BASH_PM_INJECTED_PATH
        unset BASH_PM_PYTHON_TARGET_PATH_CACHE

        return 0
    fi

    # --- Step 2: Check conditions for injection (Injection Check) ---
    # Condition: We are inside the project root AND injection flag is set AND action hasn't been done yet.
    if [[ "${PWD}"/ == "${project_root_contract}"/* ]] && \
       { [[ "${SHOULD_INJECT_PTH_FILE}" == '1' ]] || [[ "${SHOULD_INJECT_PTH_FILE}" == 'true' ]]; }  && \
       [[ "${action_done}" -ne 1 ]]; then

        _debug_echo "Injection required: Inside project root AND trigger active AND action not done."

        # Safety Check: Required configuration variables must be set
        if [[ -z "${dev_lib_path}" ]] || [[ -z "${pth_file_name}" ]]; then
            echo "[BASH PM] ERROR: Missing required configuration variables (DEV_SITE_PACKAGES_DIR or PTH_FILE_NAME). Cannot inject path." >&2
            return 1
        fi

        # Get the target Venv site-packages path dynamically
        if ! target_packages_dir=$(_get_python_site_packages_path); then
           # _get_python_site_packages_path already printed a warning/error
           return 1
        fi
        
        # Safety Check: Do not modify system paths
        if _is_python_system_path "${target_packages_dir}"; then
            echo "[BASH PM] WARNING: Target path ${target_packages_dir} is a system path. Aborting injection for safety." >&2
            return 1
        fi

        full_pth_file="${target_packages_dir}/${pth_file_name}"
        _debug_echo "Target .pth file location: ${full_pth_file}"
        _debug_echo "Developer library path to inject: ${dev_lib_path}"

        # Check existence of source/target directories before writing the file
        if [[ ! -d "${dev_lib_path}" ]] || [[ ! -d "${target_packages_dir}" ]]; then
            echo "[BASH PM] WARNING: Required directories not found. Cannot inject path." >&2
            return 1
        fi

        # Action: Write or append the developer path to the .pth file (Idempotent logic)
        if [[ ! -f "${full_pth_file}" ]]; then
            # Create a new .pth file
            if echo "${dev_lib_path}" > "${full_pth_file}"; then
                echo "[BASH PM] SUCCESS: Created new PTH file ${pth_file_name} and injected path."
                export DIRENV_PTH_ACTION_DONE=1
                export DIRENV_PTH_ACTION_TYPE="CREATED_FILE"
                export BASH_PM_INJECTED_PATH="${target_packages_dir}"
            else
                echo "[BASH PM] ERROR: Permission denied creating ${full_pth_file}. Check Venv permissions." >&2
                return 1
            fi
        else
            # Append the path if not already present in the existing .pth file
            if ! grep -qF "${dev_lib_path}" "${full_pth_file}"; then
                if echo "${dev_lib_path}" >> "${full_pth_file}"; then
                    echo "[BASH PM] SUCCESS: Appended path to existing PTH file ${pth_file_name}."
                    export DIRENV_PTH_ACTION_DONE=1
                    export DIRENV_PTH_ACTION_TYPE="ADDED_LINE"
                    export BASH_PM_INJECTED_PATH="${target_packages_dir}"
                else
                    echo "[BASH PM] ERROR: Permission denied appending to ${full_pth_file}. Check Venv permissions." >&2
                    return 1
                fi
            else
                _debug_echo "Path already exists in ${pth_file_name}. Skipping injection."
                export DIRENV_PTH_ACTION_DONE=1
                export DIRENV_PTH_ACTION_TYPE="ADDED_LINE"
                export BASH_PM_INJECTED_PATH="${target_packages_dir}"
            fi
        fi
        return 0
    fi

    _debug_echo "No action required for current state."
    return 0
}


# --- Public API functions ---


# ------------------------------------------------------------------------------
# Function: please_manage_pth (Public API Hook)
# Description: Initiate the primary logic for managing .pth files. This is the
#              authorized entry point intended for sourcing within a .envrc file.
#
# Arguments:
#   None
#
# Output:
#   Inherits output from internal functions (_manage_pth, _debug_echo, etc.).
#
# Returns:
#   0 - Success (logic executed or skipped idempotently).
#   Non-zero exit - Inherits error code from _manage_pth on failure.
# ------------------------------------------------------------------------------

please_manage_pth() {
    _manage_pth
}


# ------------------------------------------------------------------------------
# Function: check_pth_manager (Public Utility)
# Description: Output current configuration and state variables of the PTH manager.
#              Intended for manual user invocation in the terminal for diagnostics.
#
# Arguments:
#   None
#
# Output:
#   Echos formatted information to standard output (stdout).
#
# Returns:
#   0 - Success.
# ------------------------------------------------------------------------------
check_pth_manager() {
    echo "[BASH PM] Status Information (Configuration & State):"
    echo "-----------------------------------------------------"
    echo "  SHOULD_INJECT_PTH_FILE: ${SHOULD_INJECT_PTH_FILE:-N/A}"
    echo "  PTH_MANAGER_ROOT:       ${PTH_MANAGER_ROOT:-N/A}"
    echo "  DEV_SITE_PACKAGES_DIR:  ${DEV_SITE_PACKAGES_DIR:-N/A}"
    echo "  PTH_FILE_NAME:          ${PTH_FILE_NAME:-N/A}"
    echo "  DEBUG:                  ${DEBUG:-N/A}"
    echo ""
    echo "[BASH PM] Internal State Variables:"
    echo "  DIRENV_PTH_ACTION_DONE: ${DIRENV_PTH_ACTION_DONE:-N/A}"
    echo "  DIRENV_PTH_ACTION_TYPE: ${DIRENV_PTH_ACTION_TYPE:-N/A}"
    echo "  BASH_PM_INJECTED_PATH:  ${BASH_PM_INJECTED_PATH:-N/A}"
    echo "  BASH_PM_PYTHON_TARGET_PATH_CACHE: ${BASH_PM_PYTHON_TARGET_PATH_CACHE:-N/A}"
    echo ""
    echo "  To run logic, use the cd command within the project scope, or call please_manage_pth."
}


# ------------------------------------------------------------------------------
# Function: cd <directory> (Override & Hook)
# Description: Override the default shell 'cd' command. Change the directory
#              using `builtin cd` and, if successful, conditionally trigger
#              the `pth_manager` logic via `_manage_pth` based on configuration flags.
#
# Arguments:
#   <directory> - [path string] The target directory to change to (via "$@").
#
# Output:
#   Inherits output/errors from the original `builtin cd`.
#   Echos debug information via `_debug_echo` if the `DEBUG` flag is set.
#
# Returns:
#   0             - Success (directory changed and logic executed/skipped).
#   Non-zero exit - Failure (error codes inherited directly from `builtin cd`).
# ------------------------------------------------------------------------------
cd() {
    _debug_echo "CD wrapper called."

    # shellcheck disable=SC2164
    builtin cd "${@}"
    local cd_status=$?

    if [[ "${cd_status}" -ne 0 ]]; then
        _debug_echo "Builtin cd failed with status ${cd_status}. Aborting manager logic."
        return ${cd_status}
    fi

    # Trigger management logic only if the flag is explicitly '1' or 'true'
    if [[ "$SHOULD_INJECT_PTH_FILE" == '1' ]] || [[ "$SHOULD_INJECT_PTH_FILE" == 'true' ]]; then
        _debug_echo "Injection trigger is active. Calling _manage_pth."
        # _manage_pth is authorized via the _is_caller_authorized check (FUNCNAME[1] will be 'cd')
        _manage_pth
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
#     # Optional: Define global configuration variables here if needed:
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
# # Define specific project paths (adjust these paths as necessary):
# export DEV_SITE_PACKAGES_DIR="$HOME/.pyenv/versions/<venv-name>/lib/python3.13/site-packages"
# export PTH_FILE_NAME="<venv-name>.pth"
# # Optional: Enable debug output for diagnostics
# export DEBUG=1
# # Execute the manager logic immediately upon direnv load/allow
# if [[ -f ~/bin/pth_manager.sh ]]; then
#     source ~/bin/pth_manager.sh
#     # Use the authorized public hook function:
#     please_manage_pth
# fi
# --------------------------------------------------
#
# 3. Allow direnv to load the configuration:
# --------------------------------------------------
# Run 'direnv allow' in the project root directory.
# Use 'check_pth_manager' in the terminal for status diagnostics.
# --------------------------------------------------


# ==============================================================================
# TECHNICAL DEBT NOTES
# ==============================================================================
#
# FIXME: The `_manage_pth` function combines orchestration with core logic. 
#        To improve clarity and maintainability, the file creation/appending 
#        should be abstracted into dedicated helper functions with robust error handling.
#
# TODO: The current system path check (`_is_python_system_path`) only covers 
#       common prefixes (`/usr/local`, `/usr/lib`). It may need expansion for 
#       compatibility with other Linux distributions.
#
# ISSUE: The state management relies on environment variables (`DIRENV_PTH_ACTION_DONE`, etc.). 
#        This can cause cleanup logic to fail prematurely, especially in projects 
#        with nested `.envrc` files. A loud warning is issued if nested files are detected.
#
# FIXME: The state management should be migrated to a disk-based flag file (e.g., 
#        `~/.bash_pm_state`) for persistence across directory changes. This is 
#        the only robust solution for handling nested projects.
#
# TODO: Consider supporting the injection of multiple paths (multi-environment capability) 
#       by changing the input format (e.g., using an array or a configuration file).
#
# TODO: Explore using `trap EXIT` in addition to the `cd` override for guaranteed 
#       cleanup when the terminal session is closed unexpectedly. This approach 
#       is more complex to implement reliably.


# ------------------------------------------------------------------------------
# MISC NOTES
# ------------------------------------------------------------------------------
# NOTE: File locking mechanisms (`flock`) are not implemented. Race conditions 
#       are possible if multiple processes attempt to access the same .pth files 
#       concurrently in a shared environment.
# NOTE: The current path handling assumes standard POSIX filenames. Filenames 
#       containing newline characters (\n) may cause unexpected behavior.
