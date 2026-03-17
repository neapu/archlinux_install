import atexit
import subprocess
import sys
import time


LOG_FILE = None
OWNS_LOG_FILE = False
ORIGINAL_STDOUT = sys.stdout
ORIGINAL_STDERR = sys.stderr


class Colors:
    RESET = "\033[0m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"


class TeeStream:
    def __init__(self, stream, log_file):
        self.stream = stream
        self.log_file = log_file

    def write(self, data):
        self.stream.write(data)
        self.log_file.write(data)

    def flush(self):
        self.stream.flush()
        self.log_file.flush()

    def isatty(self):
        return self.stream.isatty()


def write_log(message):
    if LOG_FILE is None:
        return

    LOG_FILE.write(message)
    LOG_FILE.flush()


def setup_logging(log_file_path):
    global LOG_FILE, OWNS_LOG_FILE

    if OWNS_LOG_FILE and LOG_FILE is not None and not LOG_FILE.closed:
        shutdown_logging()

    LOG_FILE = open(log_file_path, "a", buffering=1)
    OWNS_LOG_FILE = True
    sys.stdout = TeeStream(ORIGINAL_STDOUT, LOG_FILE)
    sys.stderr = TeeStream(ORIGINAL_STDERR, LOG_FILE)
    atexit.register(shutdown_logging)


def shutdown_logging():
    global LOG_FILE, OWNS_LOG_FILE

    sys.stdout = ORIGINAL_STDOUT
    sys.stderr = ORIGINAL_STDERR

    if OWNS_LOG_FILE and LOG_FILE is not None and not LOG_FILE.closed:
        LOG_FILE.close()

    if OWNS_LOG_FILE:
        LOG_FILE = None

    OWNS_LOG_FILE = False


def attach_log_file(log_file):
    global LOG_FILE, OWNS_LOG_FILE

    if log_file is LOG_FILE:
        return

    LOG_FILE = log_file
    OWNS_LOG_FILE = False


def owns_log_file():
    return OWNS_LOG_FILE


def log_subprocess_output(cmd, stdout_text=None, stderr_text=None):
    write_log(f"\n$ {' '.join(cmd)}\n")

    if stdout_text:
        write_log("[stdout]\n")
        write_log(stdout_text)
        if not stdout_text.endswith("\n"):
            write_log("\n")

    if stderr_text:
        write_log("[stderr]\n")
        write_log(stderr_text)
        if not stderr_text.endswith("\n"):
            write_log("\n")


def print_info(message):
    print(f"{Colors.BLUE}{message}{Colors.RESET}")


def print_success(message):
    print(f"{Colors.GREEN}{message}{Colors.RESET}")


def print_error(message):
    print(f"{Colors.RED}{message}{Colors.RESET}")


def print_warning(message):
    print(f"{Colors.YELLOW}{message}{Colors.RESET}")


def run_cmd(cmd, error_message=None, capture_output=True, input_text=None):
    try:
        result = subprocess.run(cmd, capture_output=capture_output, text=True, input=input_text)
    except Exception as error:
        prefix = error_message or f"Error running {' '.join(cmd)}"
        write_log(f"\n$ {' '.join(cmd)}\n")
        print_error(f"{prefix}: {error}")
        return None

    log_subprocess_output(cmd, result.stdout, result.stderr)

    if result.returncode != 0:
        prefix = error_message or f"Error running {' '.join(cmd)}"
        detail = result.stderr.strip() if result.stderr else result.stdout.strip()
        print_error(f"{prefix}: {detail}")
        return None

    return result


def run_chroot_cmd(cmd, error_message=None, capture_output=True, input_text=None):
    return run_cmd(["arch-chroot", "/mnt"] + cmd, error_message, capture_output, input_text)


def get_system_runner(use_chroot=False):
    return run_chroot_cmd if use_chroot else run_cmd


def is_connected_ping(host):
    try:
        subprocess.run(
            ["ping", "-c", "1", "-W", "2", host],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except subprocess.CalledProcessError:
        return False


def check_network(host):
    if is_connected_ping(host):
        print_success("Network is connected.")
        return True

    print_warning("Network is not connected. Retrying in 5 seconds...")
    time.sleep(5)
    return is_connected_ping(host)