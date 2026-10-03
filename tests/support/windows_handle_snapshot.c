/* Real Windows process snapshots for failure diagnostics. The Nim caller
 * verifies a named event before and after closing it.
 * No mocks, handle closure in another process, memory dump, or VA clone.
 * https://learn.microsoft.com/windows/win32/api/processsnapshot/ns-processsnapshot-pss_handle_entry
 */
#define _WIN32_WINNT 0x0603
#include <windows.h>
#include <processsnapshot.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static void text_utf8(FILE *output, const wchar_t *value, WORD bytes) {
  char buffer[4096];
  int count = value ? WideCharToMultiByte(CP_UTF8, 0, value,
      bytes / sizeof(wchar_t), buffer, sizeof(buffer) - 1, NULL, NULL) : 0;
  if (count <= 0) count = 0;
  buffer[count] = 0;
  for (int i = 0; i < count; ++i)
    if (buffer[i] == '\n' || buffer[i] == '\r' || buffer[i] == '\t') buffer[i] = ' ';
  fputs(buffer, output);
}

static int snapshot(FILE *output, DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ |
      PROCESS_DUP_HANDLE, FALSE, pid);
  if (!process) { fprintf(output, "OpenProcess: %lu\n", GetLastError()); return 1; }
  DWORD count = 0;
  if (!GetProcessHandleCount(process, &count)) {
    fprintf(output, "GetProcessHandleCount: %lu\n", GetLastError());
    CloseHandle(process); return 1;
  }
  fprintf(output, "SNAPSHOT pid=%lu handles=%lu\n", pid, count);
  HPSS captured = NULL;
  DWORD rc = PssCaptureSnapshot(process, PSS_CAPTURE_HANDLES |
      PSS_CAPTURE_HANDLE_NAME_INFORMATION | PSS_CAPTURE_HANDLE_BASIC_INFORMATION |
      PSS_CAPTURE_HANDLE_TYPE_SPECIFIC_INFORMATION, 0, &captured);
  CloseHandle(process);
  if (rc) { fprintf(output, "PssCaptureSnapshot: %lu\n", rc); return 1; }
  HPSSWALK marker = NULL;
  rc = PssWalkMarkerCreate(NULL, &marker);
  if (rc) {
    fprintf(output, "PssWalkMarkerCreate: %lu\n", rc);
    PssFreeSnapshot(GetCurrentProcess(), captured); return 1;
  }
  PSS_HANDLE_ENTRY entry = {0};
  unsigned walked = 0;
  while ((rc = PssWalkSnapshot(captured, PSS_WALK_HANDLES, marker,
                              &entry, sizeof(entry))) == ERROR_SUCCESS) {
    fprintf(output, "HANDLE value=%p flags=%u type=%u typename=",
           entry.Handle, (unsigned)entry.Flags, (unsigned)entry.ObjectType);
    text_utf8(output, entry.TypeName, entry.TypeNameLength);
    fputs(" name=", output);
    text_utf8(output, entry.ObjectName, entry.ObjectNameLength);
    fputc('\n', output);
    ++walked;
    ZeroMemory(&entry, sizeof(entry));
  }
  fprintf(output, "SNAPSHOT walked=%u status=%lu\n", walked, rc);
  DWORD marker_rc = PssWalkMarkerFree(marker);
  DWORD free_rc = PssFreeSnapshot(GetCurrentProcess(), captured);
  if (rc != ERROR_NO_MORE_ITEMS || marker_rc || free_rc) return 1;
  return 0;
}

int rq_write_windows_handle_snapshot(unsigned int pid, const wchar_t *path) {
  FILE *output = _wfopen(path, L"wb");
  if (!output) return 1;
  int result = snapshot(output, (DWORD)pid);
  if (fclose(output)) return 1;
  return result;
}
