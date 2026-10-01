#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/variable.h>
#include <mruby/string.h>
#include <stdlib.h>

/* --- Windows (MinGW) Implementation using ConPTY --- */
#if defined(_WIN32) || defined(_WIN64)

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Same shape as the POSIX side: a reader thread fills a buffer, drain takes it,
 * eof? is "child gone and buffer empty". The child's stdin is an IO (made from
 * the pipe handle) so pty.io.print works unchanged. */

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

/* output may keep arriving this long after the child exits before we close the
 * console (closing too early can cut off the last bytes) */
#define EXIT_GRACE_MS 200
/* same cap as the POSIX reader; the reader waits above this until drained */
#define PTY_MAX_BUF (4 * 1024 * 1024)

typedef VOID *win_hpcon;
typedef HRESULT(WINAPI *create_fn)(COORD, HANDLE, HANDLE, DWORD, win_hpcon *);
typedef HRESULT(WINAPI *resize_fn)(win_hpcon, COORD);
typedef void(WINAPI *close_fn)(win_hpcon);

static create_fn p_create;
static resize_fn p_resize;
static close_fn p_close;

typedef struct win_pty {
  win_hpcon pc;
  HANDLE in_write; /* the child's stdin, handed to an IO by spawn */
  HANDLE out_read; /* the child's stdout */
  HANDLE process;
  HANDLE reader;
  DWORD pid;
  int rows, cols;

  CRITICAL_SECTION lock;
  char *buf;
  size_t len, cap;

  volatile LONG reader_done;
  volatile LONG closing;
  int pc_closed;
  int closed;
  int exited;
  ULONGLONG exit_tick;
} win_pty;

static void set_err(char *err, size_t n, const char *fmt, ...) {
  va_list ap;
  if (!err || n == 0) return;
  va_start(ap, fmt);
  vsnprintf(err, n, fmt, ap);
  va_end(ap);
}

static void win_err(char *err, size_t n, const char *what) {
  DWORD code = GetLastError();
  char msg[256] = "";
  char *e;
  FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, msg, sizeof msg, NULL);
  for (e = msg + strlen(msg); e > msg && (e[-1] == '\r' || e[-1] == '\n' || e[-1] == ' '); *--e = 0) {
  }
  set_err(err, n, "%s failed (%lu): %s", what, (unsigned long)code, msg);
}

static int load_api(void) {
  static int state = 0; /* 0 unknown, 1 ok, -1 missing */
  HMODULE k;
  if (state) return state > 0;

  k = GetModuleHandleW(L"kernel32.dll");
  if (k) {
    p_create = (create_fn)(void (*)(void))GetProcAddress(k, "CreatePseudoConsole");
    p_resize = (resize_fn)(void (*)(void))GetProcAddress(k, "ResizePseudoConsole");
    p_close = (close_fn)(void (*)(void))GetProcAddress(k, "ClosePseudoConsole");
  }
  state = (p_create && p_resize && p_close) ? 1 : -1;
  return state > 0;
}

static wchar_t *widen(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  wchar_t *w;
  if (n <= 0) return NULL;
  w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (!w) return NULL;
  MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

static void narrow(const wchar_t *w, char *out, size_t cap) {
  if (cap == 0) return;
  if (WideCharToMultiByte(CP_UTF8, 0, w, -1, out, (int)cap, NULL, NULL) <= 0) out[0] = 0;
}

/* ---- environment ----
 * The child gets the OS environment with the C runtime's on top: ENV[]= in
 * mruby goes through the CRT, which does not always reach the OS block (and the
 * hk token travels this way). */

typedef struct {
  wchar_t **v;
  size_t n, cap;
} envlist;

static size_t name_len(const wchar_t *e) {
  /* entries like "=C:=C:\dir" have their '=' first */
  const wchar_t *eq = wcschr(e + (e[0] == L'=' ? 1 : 0), L'=');
  return eq ? (size_t)(eq - e) : wcslen(e);
}

static void env_set(envlist *l, const wchar_t *entry) {
  size_t len = name_len(entry), i;
  wchar_t *copy;

  for (i = 0; i < l->n; i++) {
    if (name_len(l->v[i]) == len && _wcsnicmp(l->v[i], entry, len) == 0) {
      copy = _wcsdup(entry);
      if (copy) {
        free(l->v[i]);
        l->v[i] = copy;
      }
      return;
    }
  }
  if (l->n == l->cap) {
    size_t cap = l->cap ? l->cap * 2 : 64;
    wchar_t **v = (wchar_t **)realloc(l->v, cap * sizeof(wchar_t *));
    if (!v) return;
    l->v = v;
    l->cap = cap;
  }
  copy = _wcsdup(entry);
  if (copy) l->v[l->n++] = copy;
}

static int env_has(const envlist *l, const wchar_t *name) {
  size_t len = wcslen(name), i;
  for (i = 0; i < l->n; i++)
    if (name_len(l->v[i]) == len && _wcsnicmp(l->v[i], name, len) == 0) return 1;
  return 0;
}

static int env_cmp(const void *a, const void *b) {
  return _wcsicmp(*(wchar_t *const *)a, *(wchar_t *const *)b);
}

/* a double-NUL terminated block for CreateProcessW, or NULL (inherit) */
static wchar_t *build_env_block(void) {
  envlist l = {0};
  wchar_t *os, *block = NULL;
  size_t i;

  os = GetEnvironmentStringsW();
  if (os) {
    wchar_t *e;
    for (e = os; *e; e += wcslen(e) + 1) env_set(&l, e);
    FreeEnvironmentStringsW(os);
  }

  (void)_wgetenv(L"PATH"); /* makes the CRT build its wide environment */
  if (_wenviron) {
    wchar_t **e;
    for (e = _wenviron; *e; e++) env_set(&l, *e);
  }

  if (!env_has(&l, L"TERM")) env_set(&l, L"TERM=xterm-256color");
  if (!env_has(&l, L"COLORTERM")) env_set(&l, L"COLORTERM=truecolor");

  if (l.n > 0) {
    size_t total = 1;
    qsort(l.v, l.n, sizeof(wchar_t *), env_cmp);
    for (i = 0; i < l.n; i++) total += wcslen(l.v[i]) + 1;
    block = (wchar_t *)malloc(total * sizeof(wchar_t));
    if (block) {
      wchar_t *w = block;
      for (i = 0; i < l.n; i++) {
        size_t n = wcslen(l.v[i]) + 1;
        memcpy(w, l.v[i], n * sizeof(wchar_t));
        w += n;
      }
      *w = 0;
    }
  }

  for (i = 0; i < l.n; i++) free(l.v[i]);
  free(l.v);
  return block;
}

/* pwsh, then Windows PowerShell, then %COMSPEC%, as a quoted command line */
static void win_default_shell(char *out, size_t cap) {
  static const wchar_t *candidates[] = {L"pwsh.exe", L"powershell.exe"};
  wchar_t path[MAX_PATH * 2];
  char utf8[MAX_PATH * 4];
  size_t i;
  DWORD n;

  for (i = 0; i < sizeof candidates / sizeof candidates[0]; i++) {
    n = SearchPathW(NULL, candidates[i], NULL, (DWORD)(sizeof path / sizeof path[0]), path, NULL);
    if (n > 0 && n < sizeof path / sizeof path[0]) {
      narrow(path, utf8, sizeof utf8);
      snprintf(out, cap, "\"%s\"", utf8);
      return;
    }
  }

  n = GetEnvironmentVariableW(L"COMSPEC", path, (DWORD)(sizeof path / sizeof path[0]));
  if (n > 0 && n < sizeof path / sizeof path[0]) {
    narrow(path, utf8, sizeof utf8);
    snprintf(out, cap, "\"%s\"", utf8);
    return;
  }

  snprintf(out, cap, "cmd.exe");
}

static DWORD WINAPI win_reader_main(LPVOID arg) {
  win_pty *p = (win_pty *)arg;
  char chunk[16384];
  DWORD n;

  while (ReadFile(p->out_read, chunk, (DWORD)sizeof chunk, &n, NULL)) {
    size_t have;
    if (n == 0) continue;

    /* backpressure, but never hold up a close */
    while (!p->closing) {
      EnterCriticalSection(&p->lock);
      have = p->len;
      LeaveCriticalSection(&p->lock);
      if (have + n <= PTY_MAX_BUF) break;
      Sleep(2);
    }

    EnterCriticalSection(&p->lock);
    if (p->len + n > p->cap) {
      size_t cap = p->cap ? p->cap : 8192;
      char *b;
      while (cap < p->len + n) cap *= 2;
      b = (char *)realloc(p->buf, cap);
      if (!b) {
        LeaveCriticalSection(&p->lock);
        break;
      }
      p->buf = b;
      p->cap = cap;
    }
    memcpy(p->buf + p->len, chunk, n);
    p->len += n;
    LeaveCriticalSection(&p->lock);
  }

  InterlockedExchange(&p->reader_done, 1);
  return 0;
}

static void win_release(win_pty *p) {
  if (p->pc && !p->pc_closed) {
    InterlockedExchange(&p->closing, 1);
    p_close(p->pc);
    p->pc_closed = 1;
  }
  if (p->process) {
    if (WaitForSingleObject(p->process, 300) != WAIT_OBJECT_0) TerminateProcess(p->process, 1);
    CloseHandle(p->process);
    p->process = NULL;
  }
  if (p->in_write) {
    CloseHandle(p->in_write);
    p->in_write = NULL;
  }
  if (p->reader) {
    WaitForSingleObject(p->reader, 2000);
    CloseHandle(p->reader);
    p->reader = NULL;
  }
  if (p->out_read) {
    CloseHandle(p->out_read);
    p->out_read = NULL;
  }
}

static win_pty *win_pty_spawn(const char *cmd, int cols, int rows, char *err, size_t errlen) {
  char shell[MAX_PATH * 4];
  win_pty *p;
  HANDLE in_read = NULL, out_write = NULL;
  wchar_t *wcmd = NULL, *env = NULL;
  STARTUPINFOEXW si;
  PROCESS_INFORMATION pi;
  int attrs = 0;
  COORD size;
  HRESULT hr;
  SIZE_T attr_size = 0;

  if (!load_api()) {
    set_err(err, errlen, "ConPTY is not available (it needs Windows 10 version 1809 or newer)");
    return NULL;
  }

  if (!cmd || !cmd[0]) {
    win_default_shell(shell, sizeof shell);
    cmd = shell;
  }

  p = (win_pty *)calloc(1, sizeof *p);
  if (!p) {
    set_err(err, errlen, "out of memory");
    return NULL;
  }
  InitializeCriticalSection(&p->lock);

  ZeroMemory(&si, sizeof si);
  ZeroMemory(&pi, sizeof pi);
  if (cols < 1) cols = 80;
  if (rows < 1) rows = 24;
  p->rows = rows;
  p->cols = cols;

  if (!CreatePipe(&in_read, &p->in_write, NULL, 65536) || !CreatePipe(&p->out_read, &out_write, NULL, 65536)) {
    win_err(err, errlen, "CreatePipe");
    goto fail;
  }

  size.X = (SHORT)cols;
  size.Y = (SHORT)rows;
  hr = p_create(size, in_read, out_write, 0, &p->pc);
  /* the console holds its own references now */
  CloseHandle(in_read);
  in_read = NULL;
  CloseHandle(out_write);
  out_write = NULL;
  if (FAILED(hr)) {
    set_err(err, errlen, "CreatePseudoConsole failed (0x%08lx)", (unsigned long)hr);
    p->pc = NULL;
    goto fail;
  }

  si.StartupInfo.cb = sizeof si;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
  si.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attr_size);
  if (!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size)) {
    win_err(err, errlen, "InitializeProcThreadAttributeList");
    goto fail;
  }
  attrs = 1;
  if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, p->pc, sizeof(p->pc), NULL, NULL)) {
    win_err(err, errlen, "UpdateProcThreadAttribute");
    goto fail;
  }

  wcmd = widen(cmd); /* CreateProcessW may modify its command line */
  if (!wcmd) {
    set_err(err, errlen, "could not convert the command line to UTF-16");
    goto fail;
  }
  env = build_env_block();

  if (!CreateProcessW(NULL, wcmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, env, NULL, &si.StartupInfo, &pi)) {
    char what[MAX_PATH * 4 + 32];
    snprintf(what, sizeof what, "CreateProcess(%s)", cmd);
    win_err(err, errlen, what);
    goto fail;
  }

  free(env);
  free(wcmd);
  DeleteProcThreadAttributeList(si.lpAttributeList);
  HeapFree(GetProcessHeap(), 0, si.lpAttributeList);

  CloseHandle(pi.hThread);
  p->process = pi.hProcess;
  p->pid = pi.dwProcessId;

  p->reader = CreateThread(NULL, 0, win_reader_main, p, 0, NULL);
  if (!p->reader) {
    win_err(err, errlen, "CreateThread");
    TerminateProcess(p->process, 1);
    win_release(p);
    DeleteCriticalSection(&p->lock);
    free(p);
    return NULL;
  }
  return p;

fail:
  free(env);
  free(wcmd);
  if (si.lpAttributeList) {
    if (attrs) DeleteProcThreadAttributeList(si.lpAttributeList);
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList);
  }
  if (in_read) CloseHandle(in_read);
  if (out_write) CloseHandle(out_write);
  win_release(p);
  DeleteCriticalSection(&p->lock);
  free(p);
  return NULL;
}

static void win_poll_exit(win_pty *p) {
  if (p->exited || !p->process) return;
  if (WaitForSingleObject(p->process, 0) == WAIT_OBJECT_0) {
    p->exited = 1;
    p->exit_tick = GetTickCount64();
  }
}

/* ConPTY never closes its output pipe by itself: once the child is gone and has
 * had a moment to flush, closing the console is what ends the stream. */
static int win_pty_eof(win_pty *p) {
  int empty;

  win_poll_exit(p);
  if (p->exited && !p->pc_closed && GetTickCount64() - p->exit_tick >= EXIT_GRACE_MS) {
    InterlockedExchange(&p->closing, 1);
    p_close(p->pc);
    p->pc_closed = 1;
  }

  if (!InterlockedCompareExchange(&p->reader_done, 0, 0)) return 0;

  EnterCriticalSection(&p->lock);
  empty = p->len == 0;
  LeaveCriticalSection(&p->lock);
  return empty;
}

/* the whole buffer as a malloc'd block (caller frees); 0 when empty */
static size_t win_pty_drain(win_pty *p, char **out) {
  size_t n;
  *out = NULL;

  EnterCriticalSection(&p->lock);
  n = p->len;
  if (n) {
    *out = p->buf;
    p->buf = NULL;
    p->len = p->cap = 0;
  }
  LeaveCriticalSection(&p->lock);
  return n;
}

static void win_pty_free(win_pty *p) {
  if (!p->closed) {
    p->closed = 1;
    win_release(p);
  }
  free(p->buf);
  DeleteCriticalSection(&p->lock);
  free(p);
}

static win_pty *get_pty(mrb_state *mrb, mrb_value self) {
  mrb_value v = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@reader"));
  return mrb_nil_p(v) ? NULL : (win_pty *)mrb_cptr(v);
}

static mrb_value mrb_pty_open(mrb_state *mrb, mrb_value self) {
  mrb_raise(mrb, E_NOTIMP_ERROR, "PTY.open is not supported on Windows, use PTY.spawn");
  return mrb_nil_value();
}

static mrb_value mrb_pty_default_shell(mrb_state *mrb, mrb_value self) {
  char shell[1024];
  win_default_shell(shell, sizeof shell);
  return mrb_str_new_cstr(mrb, shell);
}

/* PTY.spawn(cmd = nil) -> [pty, pid]. cmd is a command line; nil starts PowerShell / cmd. */
static mrb_value mrb_pty_spawn(mrb_state *mrb, mrb_value self) {
  mrb_value shell_arg = mrb_nil_value();
  char err[512] = "";
  win_pty *p;
  int fd;
  mrb_value mode, margs[2], stdin_io, master_pty, ary;

  mrb_get_args(mrb, "|S", &shell_arg);

  p = win_pty_spawn(mrb_nil_p(shell_arg) ? NULL : RSTRING_CSTR(mrb, shell_arg), 80, 24, err, sizeof err);
  if (!p) mrb_raisef(mrb, E_RUNTIME_ERROR, "PTY.spawn: %s", err);

  /* the child's stdin as an IO, like the master side on POSIX. The IO owns the handle now. */
  fd = _open_osfhandle((intptr_t)p->in_write, _O_WRONLY | _O_BINARY);
  if (fd < 0) {
    win_pty_free(p);
    mrb_raise(mrb, E_RUNTIME_ERROR, "PTY.spawn: _open_osfhandle failed");
  }
  p->in_write = NULL;

  mode = mrb_str_new_cstr(mrb, "w");
  margs[0] = mrb_fixnum_value(fd);
  margs[1] = mode;
  stdin_io = mrb_obj_new(mrb, mrb_class_get(mrb, "IO"), 2, margs);
  master_pty = mrb_obj_new(mrb, mrb_class_get(mrb, "PTY"), 1, &stdin_io);
  mrb_iv_set(mrb, master_pty, mrb_intern_lit(mrb, "@reader"), mrb_cptr_value(mrb, p));

  ary = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, ary, master_pty);
  mrb_ary_push(mrb, ary, mrb_fixnum_value((mrb_int)p->pid));
  return ary;
}

static mrb_value mrb_pty_drain(mrb_state *mrb, mrb_value self) {
  win_pty *p = get_pty(mrb, self);
  char *buf;
  size_t n;
  mrb_value s;

  if (!p) return mrb_str_new_lit(mrb, "");
  n = win_pty_drain(p, &buf);
  if (n == 0) return mrb_str_new_lit(mrb, "");

  s = mrb_str_new(mrb, buf, (mrb_int)n);
  free(buf);
  return s;
}

static mrb_value mrb_pty_eof_p(mrb_state *mrb, mrb_value self) {
  win_pty *p = get_pty(mrb, self);
  return mrb_bool_value(!p || win_pty_eof(p));
}

static mrb_value mrb_pty_size(mrb_state *mrb, mrb_value self) {
  win_pty *p = get_pty(mrb, self);
  mrb_value ary = mrb_ary_new(mrb);

  mrb_ary_push(mrb, ary, mrb_int_value(mrb, p ? p->rows : 0));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, p ? p->cols : 0));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, 0));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, 0));
  return ary;
}

/* (rows, cols, xpixels, ypixels); the pixel sizes mean nothing to ConPTY */
static mrb_value mrb_pty_set_size(mrb_state *mrb, mrb_value self) {
  int row, col, x, y;
  win_pty *p;
  COORD size;

  mrb_get_args(mrb, "iiii", &row, &col, &x, &y);
  p = get_pty(mrb, self);
  if (!p || p->pc_closed || row < 1 || col < 1) mrb_raise(mrb, E_RUNTIME_ERROR, "Can't set winsize");

  size.X = (SHORT)col;
  size.Y = (SHORT)row;
  if (FAILED(p_resize(p->pc, size))) mrb_raise(mrb, E_RUNTIME_ERROR, "Can't set winsize");
  p->rows = row;
  p->cols = col;
  return mrb_nil_value();
}

static mrb_value mrb_pty_close(mrb_state *mrb, mrb_value self) {
  win_pty *p = get_pty(mrb, self);
  mrb_value io;

  if (!p) return mrb_nil_value();

  win_pty_free(p);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@reader"), mrb_nil_value());

  /* the stdin IO owns its handle */
  io = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@io"));
  if (!mrb_nil_p(io) && !mrb_test(mrb_funcall(mrb, io, "closed?", 0))) mrb_funcall(mrb, io, "close", 0);
  return mrb_nil_value();
}

/* --- POSIX (Linux/macOS) Implementation --- */
#else

#if defined(__linux__)
#include <pty.h>
#elif defined(__APPLE__)
#include <util.h>
#include <stdlib.h>
#endif

#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>

#define PTY_MAX_BUF (4 * 1024 * 1024)

typedef struct {
  int fd;
  char *buf;
  int pid;
  size_t len, cap;
  int eof;
  pthread_mutex_t mu;
  pthread_cond_t room;
  pthread_t thread;
} pty_reader;

static void *reader_main(void *arg) {
  pty_reader *r = arg;
  char tmp[65536];

  for (;;) {
    ssize_t n = read(r->fd, tmp, sizeof tmp);
    if (n < 0 && errno == EINTR) continue;

    pthread_mutex_lock(&r->mu);
    if (n <= 0) {                 /* EOF, or EIO once the child exits (macOS) */
      r->eof = 1;
      pthread_mutex_unlock(&r->mu);
      return NULL;
    }

    /* backpressure: block the reader, which fills the pty and blocks the writer */
    while (r->len + n > PTY_MAX_BUF)
      pthread_cond_wait(&r->room, &r->mu);

    if (r->len + n > r->cap) {
      r->cap = (r->len + n) * 2;
      r->buf = realloc(r->buf, r->cap);
    }
    memcpy(r->buf + r->len, tmp, n);
    r->len += n;
    pthread_mutex_unlock(&r->mu);
  }
}

static pty_reader *get_reader(mrb_state *mrb, mrb_value self) {
  return (pty_reader *)mrb_cptr(mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@reader")));
}

static mrb_value mrb_pty_drain(mrb_state *mrb, mrb_value self) {
  pty_reader *r = get_reader(mrb, self);

  pthread_mutex_lock(&r->mu);
  mrb_value s = mrb_str_new(mrb, r->buf, r->len);
  r->len = 0;
  pthread_cond_signal(&r->room);
  pthread_mutex_unlock(&r->mu);

  return s;
}

static mrb_value mrb_pty_eof_p(mrb_state *mrb, mrb_value self) {
  pty_reader *r = get_reader(mrb, self);

  pthread_mutex_lock(&r->mu);
  int done = r->eof && r->len == 0;
  pthread_mutex_unlock(&r->mu);

  return mrb_bool_value(done);
}

static mrb_value mrb_pty_open(mrb_state *mrb, mrb_value self) 
{
  int master_fd, slave_fd;

  if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) < 0) {
    mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"), "openpty failed");
  }

  mrb_value mfd = mrb_fixnum_value(master_fd);
  mrb_value sfd = mrb_fixnum_value(slave_fd);
  mrb_value mode = mrb_str_new_cstr(mrb, "r+");
  mrb_value margs[2] = {mfd, mode};
  mrb_value sargs[2] = {sfd, mode};

  struct RClass *io_class = mrb_class_get(mrb, "IO");
  mrb_value master_io = mrb_obj_new(mrb, io_class, 2, margs);
  mrb_value slave_io  = mrb_obj_new(mrb, io_class, 2, sargs);
  mrb_value ary = mrb_ary_new_capa(mrb, 2);

  mrb_ary_push(mrb, ary, master_io);
  mrb_ary_push(mrb, ary, slave_io);

  return ary;
}

/* the user's shell, like a terminal emulator would start it */
static mrb_value mrb_pty_default_shell(mrb_state *mrb, mrb_value self)
{
  const char *shell = getenv("SHELL");
  return mrb_str_new_cstr(mrb, (shell && shell[0]) ? shell : "/bin/bash");
}

static mrb_value mrb_pty_spawn(mrb_state *mrb, mrb_value self) 
{
  mrb_value shell_arg = mrb_nil_value();
  mrb_get_args(mrb, "|S", &shell_arg);
  const char *shell = mrb_nil_p(shell_arg) ? "/bin/bash" : RSTRING_CSTR(mrb, shell_arg);

  int master_fd, slave_fd;
  struct winsize ws;
  ws.ws_row = 24;
  ws.ws_col = 80;
  ws.ws_xpixel = 0;
  ws.ws_ypixel = 0;

  if (openpty(&master_fd, &slave_fd, NULL, NULL, &ws) < 0) {
    mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"), "openpty failed");
  }

  struct termios ts;
  tcgetattr(slave_fd, &ts);
  // ts.c_iflag |= IUTF8;      // example
  tcsetattr(slave_fd, TCSANOW, &ts);   // before fork

  pid_t pid = fork();
  if (pid < 0) {
    close(master_fd);
    close(slave_fd);
    mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"), "fork failed");
  }

  if (pid == 0) {
    close(master_fd);

    if (setsid() < 0) _exit(127);

#ifdef TIOCSCTTY
    if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) _exit(127);
#endif

    dup2(slave_fd, STDIN_FILENO);
    dup2(slave_fd, STDOUT_FILENO);
    dup2(slave_fd, STDERR_FILENO);
    if (slave_fd > STDERR_FILENO) close(slave_fd);

    setenv("TERM", "xterm-256color", 1);

    execl(shell, shell, "-i", (char *)NULL);
    _exit(127);
  }

  close(slave_fd);

  mrb_value mfd = mrb_fixnum_value(master_fd);
  mrb_value mode = mrb_str_new_cstr(mrb, "r+");
  mrb_value margs[2] = {mfd, mode};
  struct RClass *io_class = mrb_class_get(mrb, "IO");
  struct RClass *pty_class = mrb_class_get(mrb, "PTY");
  mrb_value master_io = mrb_obj_new(mrb, io_class, 2, margs);
  mrb_value master_pty = mrb_obj_new(mrb, pty_class, 1, &master_io);

  pty_reader *r = calloc(1, sizeof *r);
  r->fd = master_fd;
  r->pid = pid;
  pthread_mutex_init(&r->mu, NULL);
  pthread_cond_init(&r->room, NULL);
  pthread_create(&r->thread, NULL, reader_main, r);
  mrb_iv_set(mrb, master_pty, mrb_intern_lit(mrb, "@reader"), mrb_cptr_value(mrb, r));

  mrb_value ary = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, ary, master_pty);
  mrb_ary_push(mrb, ary, mrb_fixnum_value((mrb_int)pid));
  return ary;
}

mrb_value mrb_pty_size(mrb_state* mrb, mrb_value self)
{
  mrb_value io = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@io"));
  int fd = mrb_int(mrb, mrb_funcall(mrb, io, "fileno", 0, NULL)); 
  struct winsize ws;
  int ret = ioctl(fd, TIOCGWINSZ, &ws);
  if (ret < 0) mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"), "Can't get winsize");

  mrb_value ary = mrb_ary_new(mrb);
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, ws.ws_row));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, ws.ws_col));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, ws.ws_xpixel));
  mrb_ary_push(mrb, ary, mrb_int_value(mrb, ws.ws_ypixel));
  return ary;

}

mrb_value mrb_pty_set_size(mrb_state* mrb, mrb_value self)
{
  int row;
  int col;
  int x;
  int y;

  mrb_get_args(mrb, "iiii", &row, &col, &x, &y);
  mrb_value io = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@io"));
  int fd = mrb_int(mrb, mrb_funcall(mrb, io, "fileno", 0, NULL)); 
  struct winsize ws;
  ws.ws_row = row;
  ws.ws_col = col;
  ws.ws_xpixel = x;
  ws.ws_ypixel = y;
  int ret = ioctl(fd, TIOCSWINSZ, &ws);
  if (ret < 0) mrb_raise(mrb, mrb_class_get(mrb, "RuntimeError"), "Can't set winsize");

  return mrb_nil_value();
}

#include <signal.h>
#include <sys/wait.h>

static mrb_value mrb_pty_close(mrb_state *mrb, mrb_value self) {
  pty_reader *r = get_reader(mrb, self);

  kill(r->pid, SIGHUP);          /* wakes the blocked read() */
  pthread_join(r->thread, NULL); /* so don't pthread_detach in spawn */
  waitpid(r->pid, NULL, 0);      /* reap the child */
  close(r->fd);

  pthread_mutex_destroy(&r->mu);
  pthread_cond_destroy(&r->room);
  free(r->buf);
  free(r);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@reader"), mrb_nil_value());
  return mrb_nil_value();
}

#endif /* POSIX vs Windows */

/* --- shared --- */

mrb_value mrb_pty_init(mrb_state* mrb, mrb_value self)
{
  mrb_value io;
  mrb_get_args(mrb, "o", &io);
  mrb_iv_set(mrb, self, mrb_intern_lit(mrb, "@io"), io);
  return self;
}

mrb_value mrb_pty_io(mrb_state* mrb, mrb_value self)
{
  return mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@io"));
}

void mrb_mruby_pty_gem_init(mrb_state *mrb) 
{
  struct RClass *pty = mrb_define_class(mrb, "PTY", mrb->object_class);
  mrb_define_class_method(mrb, pty, "open", mrb_pty_open, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, pty, "spawn", mrb_pty_spawn, MRB_ARGS_OPT(1));
  mrb_define_class_method(mrb, pty, "default_shell", mrb_pty_default_shell, MRB_ARGS_NONE());

  mrb_define_method(mrb, pty, "initialize", mrb_pty_init, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, pty, "io", mrb_pty_io, MRB_ARGS_NONE());
  mrb_define_method(mrb, pty, "set_size", mrb_pty_set_size, MRB_ARGS_REQ(4));
  mrb_define_method(mrb, pty, "close", mrb_pty_close, MRB_ARGS_NONE());
  mrb_define_method(mrb, pty, "drain", mrb_pty_drain, MRB_ARGS_NONE());
  mrb_define_method(mrb, pty, "eof?", mrb_pty_eof_p, MRB_ARGS_NONE());
  mrb_define_method(mrb, pty, "size", mrb_pty_size, MRB_ARGS_NONE());
}

void mrb_mruby_pty_gem_final(mrb_state *mrb) 
{
}
