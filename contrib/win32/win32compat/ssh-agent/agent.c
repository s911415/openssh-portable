/*
 * Author: Manoj Ampalam <manoj.ampalam@microsoft.com>
 * ssh-agent implementation on Windows
 * 
 * Copyright (c) 2015 Microsoft Corp.
 * All rights reserved
 *
 * Microsoft openssh win32 port
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
#include "config.h"
#include "agent.h"
#include <sddl.h>
#include <UserEnv.h>
#include "..\misc_internal.h"
#include <pwd.h>
#include "xmalloc.h"

#define BUFSIZE 5 * 1024

extern char* allowed_providers;
extern int remote_add_provider;

char* sshagent_con_username;
HANDLE sshagent_client_primary_token;

static HANDLE ioc_port = NULL;
static BOOL debug_mode = FALSE;

#define AGENT_PIPE_ID L"\\\\.\\pipe\\openssh-ssh-agent"

static HANDLE event_stop_agent;
static OVERLAPPED ol;
static 	HANDLE pipe;
static	SECURITY_ATTRIBUTES sa;

static size_t nsession_ids;
static struct hostkey_sid *session_ids;
static struct dest_constraint *dest_constraints;
static size_t ndest_constraints;

static void
agent_cleanup() 
{
	if (ol.hEvent != NULL)
		CloseHandle(ol.hEvent);
	if (pipe != INVALID_HANDLE_VALUE)
		CloseHandle(pipe);
	if (ioc_port)
		CloseHandle(ioc_port);
	return;
}

static DWORD WINAPI 
iocp_work(LPVOID lpParam) 
{
	DWORD bytes;
	struct agent_connection* con = NULL;
	OVERLAPPED *p_ol;
	while (1) {
		con = NULL;
		p_ol = NULL;
		if (GetQueuedCompletionStatus(ioc_port, &bytes, &(ULONG_PTR)con, &p_ol, INFINITE) == FALSE) {
			debug("iocp error: %d on %p", GetLastError(), con);
			if (con)
				agent_connection_on_error(con, GetLastError());
			else
				return 0;
		}
		else
			agent_connection_on_io(con, bytes, p_ol);
	}
}

static void 
agent_listen_loop() 
{
	DWORD  r;
	HANDLE wait_events[2];

	wait_events[0] = event_stop_agent;
	wait_events[1] = ol.hEvent;

	wchar_t* sddl_str;
	memset(&sa, 0, sizeof(SECURITY_ATTRIBUTES));
	sa.nLength = sizeof(sa);
	/*
	 * SDDL - GA to System and Builtin/Admins and restricted access to Authenticated users
	 * 0x12019b - FILE_GENERIC_READ/WRITE minus FILE_CREATE_PIPE_INSTANCE
	 */
	sddl_str = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x12019b;;;AU)";
	if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_str, SDDL_REVISION_1,
		&sa.lpSecurityDescriptor, &sa.nLength))
		fatal("cannot convert sddl ERROR:%d", GetLastError());

	sa.bInheritHandle = FALSE;

	while (1) {
		pipe = CreateNamedPipeW(
			AGENT_PIPE_ID,		  // pipe name 
			PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,       // read/write access 
			PIPE_TYPE_BYTE |       // message type pipe 
			PIPE_READMODE_BYTE |   // message-read mode 
			PIPE_REJECT_REMOTE_CLIENTS | // no remote client connections allowed
			PIPE_WAIT,                // blocking mode 
			PIPE_UNLIMITED_INSTANCES, // max. instances  
			BUFSIZE,                  // output buffer size 
			BUFSIZE,                  // input buffer size 
			0,                        // client time-out 
			&sa);

		if (pipe == INVALID_HANDLE_VALUE) {
			verbose("cannot create listener pipe ERROR:%d", GetLastError());
			SetEvent(event_stop_agent);
		} else if (ConnectNamedPipe(pipe, &ol) != FALSE) {
			verbose("ConnectNamedPipe returned TRUE unexpectedly ");
			SetEvent(event_stop_agent);
		}
				
		if (GetLastError() == ERROR_PIPE_CONNECTED) {
			debug("Client has already connected");
			SetEvent(ol.hEvent);
		} else if (GetLastError() != ERROR_IO_PENDING) {
			debug("ConnectNamedPipe failed ERROR: %d", GetLastError());
			SetEvent(event_stop_agent);
		}

		r = WaitForMultipleObjects(2, wait_events, FALSE, INFINITE);
		if (r == WAIT_OBJECT_0) {
			/*received signal to shutdown*/
			debug("shutting down");
			agent_cleanup();
			return;
		} else if ((r > WAIT_OBJECT_0) && (r <= (WAIT_OBJECT_0 + 1))) {
			/* process incoming connection */
			HANDLE con = pipe;
			DWORD client_pid = 0;
			pipe = INVALID_HANDLE_VALUE;
			GetNamedPipeClientProcessId(con, &client_pid);
			verbose("client pid %d connected", client_pid);
			if (debug_mode) {
				agent_process_connection(con);
				agent_cleanup();
				return;
			} else {
				/* spawn a child to take care of this*/
				wchar_t path[PATH_MAX], module_path[PATH_MAX];
				PROCESS_INFORMATION pi;
				STARTUPINFOW si;

				si.cb = sizeof(STARTUPINFOW);
				memset(&si, 0, sizeof(STARTUPINFOW));
				GetModuleFileNameW(NULL, module_path, PATH_MAX);
				SetHandleInformation(con, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
				if (remote_add_provider == 1) {
					if (swprintf_s(path, PATH_MAX, L"%s %d %s -P \"%S\"", module_path, (int)(intptr_t)con, L"-Oallow-remote-pkcs11", allowed_providers) == -1)
						verbose("Failed to create child process %ls ERROR:%d", module_path, GetLastError());
				}
				else {
					if (swprintf_s(path, PATH_MAX, L"%s %d -P \"%S\"", module_path, (int)(intptr_t)con, allowed_providers) == -1)
						verbose("Failed to create child process %ls ERROR:%d", module_path, GetLastError());
				}
				if (CreateProcessW(NULL, path, NULL, NULL, TRUE, DETACHED_PROCESS, NULL, NULL, &si, &pi) == FALSE) {
					verbose("Failed to create child process %ls ERROR:%d", module_path, GetLastError());
				} else {
					debug("spawned worker %d for agent client pid %d ", pi.dwProcessId, client_pid);
					CloseHandle(pi.hProcess);
					CloseHandle(pi.hThread);
				}
				SetHandleInformation(con, HANDLE_FLAG_INHERIT, 0);
				CloseHandle(con);				
			}
			
		} else {
			fatal("wait on events ended with %d ERROR:%d", r, GetLastError());
		}

	}
}

void 
agent_cleanup_connection(struct agent_connection* con) 
{
	debug("connection %p clean up", con);
	CloseHandle(con->pipe_handle);
	if (con->client_impersonation_token)
			CloseHandle(con->client_impersonation_token);
	if (con->client_process_handle)
		CloseHandle(con->client_process_handle);

	for (size_t i = 0; i < con->nsession_ids; i++) {
		sshkey_free(con->session_ids[i].key);
		sshbuf_free(con->session_ids[i].sid);
	}
	free(con->session_ids);
	con->nsession_ids = 0;
	
	free(con);
	CloseHandle(ioc_port);
	ioc_port = NULL;

	if(sshagent_con_username) {
		free(sshagent_con_username);
		sshagent_con_username = NULL;
	}

#ifdef ENABLE_PKCS11
	if (sshagent_client_primary_token)
		CloseHandle(sshagent_client_primary_token);

	pkcs11_terminate();
#endif
}

void 
agent_shutdown() 
{
	SetEvent(event_stop_agent);
}

void
agent_start(BOOL dbg_mode) 
{
	int r;
	HKEY agent_root = NULL;
	DWORD process_id = GetCurrentProcessId();
	wchar_t* sddl_str;
	
	verbose("%s pid:%d, dbg:%d", __FUNCTION__, process_id, dbg_mode);
	debug_mode = dbg_mode;

	memset(&sa, 0, sizeof(SECURITY_ATTRIBUTES));
	sa.nLength = sizeof(sa);

	// SDDL - FullAcess to System and Builtin/Admins
	sddl_str = L"D:PAI(A;OICI;KA;;;SY)(A;OICI;KA;;;BA)";
	if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_str, SDDL_REVISION_1,
	    &sa.lpSecurityDescriptor, &sa.nLength))
		fatal("cannot convert sddl ERROR:%d", GetLastError());
	if ((r = RegCreateKeyExW(HKEY_LOCAL_MACHINE, SSH_AGENT_ROOT, 0, 0, 0, KEY_WRITE, &sa, &agent_root, 0)) != ERROR_SUCCESS)
		fatal("cannot create agent root reg key, ERROR:%d", r);
	if ((r = RegSetValueExW(agent_root, L"ProcessID", 0, REG_DWORD, (BYTE*)&process_id, 4)) != ERROR_SUCCESS)
		fatal("cannot publish agent master process id ERROR:%d", r);
	if ((event_stop_agent = CreateEvent(NULL, TRUE, FALSE, NULL)) == NULL)
		fatal("cannot create global stop event ERROR:%d", GetLastError());
	if ((ol.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL)) == NULL)
		fatal("cannot create event ERROR:%d", GetLastError());
	pipe = INVALID_HANDLE_VALUE;
	sa.bInheritHandle = FALSE;
	agent_listen_loop();
}

static char*
con_type_to_string(struct agent_connection* con)
{
	switch (con->client_type) {
	case UNKNOWN:
		return "unknown";
	case NONADMIN_USER:
		return "restricted user";
	case ADMIN_USER:
		return "administrator";
	case SYSTEM:
		return "system";
	case SERVICE:
		return "service";
	default:
		return "unexpected";
	}
}

static int
get_con_client_info(struct agent_connection* con)
{
	int r = -1;
	char sid[SECURITY_MAX_SID_SIZE];
	ULONG client_pid;
	DWORD reg_dom_len = 0, info_len = 0, sid_size;
	DWORD sshd_sid_len = 0;
	PSID sshd_sid = NULL;
	HANDLE client_primary_token = NULL, client_impersonation_token = NULL, client_process_handle = NULL;
	TOKEN_USER* info = NULL;
	BOOL isMember = FALSE;

	if (GetNamedPipeClientProcessId(con->pipe_handle, &client_pid) == FALSE ||
		(client_process_handle = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_DUP_HANDLE, FALSE, client_pid)) == NULL ||
		OpenProcessToken(client_process_handle, TOKEN_QUERY | TOKEN_DUPLICATE, &client_primary_token) == FALSE ||
		DuplicateToken(client_primary_token, SecurityImpersonation, &client_impersonation_token) == FALSE) {
		error("cannot retrieve client impersonation token");
		goto done;
	}

	if (GetTokenInformation(client_primary_token, TokenUser, NULL, 0, &info_len) == TRUE ||
		(info = (TOKEN_USER*)malloc(info_len)) == NULL) // CodeQL [SM02320]: GetTokenInformation will initialize info
		goto done;

	if (GetTokenInformation(client_primary_token, TokenUser, info, info_len, &info_len) == FALSE)
		goto done;
	
	/* check if its localsystem */
	if (IsWellKnownSid(info->User.Sid, WinLocalSystemSid)) {
		con->client_type = SYSTEM;
		r = 0;
		goto done;
	}

	/* check if its LS or NS */
	if (IsWellKnownSid(info->User.Sid, WinNetworkServiceSid) ||
		IsWellKnownSid(info->User.Sid, WinLocalServiceSid)) {
		con->client_type = SERVICE;
		r = 0;
		goto done;
	}

	// Get client primary token
	if (DuplicateTokenEx(client_primary_token, TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE, NULL, SecurityImpersonation, TokenPrimary, &sshagent_client_primary_token) == FALSE) {
		error_f("Failed to duplicate the primary token. error:%d", GetLastError());
	}

	// Get username
	sshagent_con_username= get_username(info->User.Sid);
	if (sshagent_con_username)
		debug_f("sshagent_con_username: %s", sshagent_con_username);
	else
		error_f("Failed to get the userName");

	/* check if its admin */
	{
		sid_size = SECURITY_MAX_SID_SIZE;
		if (CreateWellKnownSid(WinBuiltinAdministratorsSid, NULL, sid, &sid_size) == FALSE)
			goto done;
		if (CheckTokenMembership(client_impersonation_token, sid, &isMember) == FALSE)
			goto done;
		if (isMember) {
			con->client_type = ADMIN_USER;
			r = 0;
			goto done;
		}
	}

	/* none of above */
	con->client_type = NONADMIN_USER;
	r = 0;
done:
	debug("client type: %s", con_type_to_string(con));
	con->nsession_ids = 0;

	if (sshd_sid)
		free(sshd_sid);
	if (info)
		free(info);
	if (client_primary_token)
		CloseHandle(client_primary_token);

	if (r == 0) {
		con->client_process_handle = client_process_handle;
		con->client_impersonation_token = client_impersonation_token;
	}
	else {
		if (client_process_handle)
			CloseHandle(client_process_handle);
		if (client_impersonation_token)
			CloseHandle(client_impersonation_token);
	}

	return r;
}

void 
agent_process_connection(HANDLE pipe) 
{
	struct agent_connection* con;
	verbose("%s pipe:%p", __FUNCTION__, pipe);

	if ((ioc_port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, (ULONG_PTR)NULL, 0)) == NULL)
		fatal("cannot create ioc port ERROR:%d", GetLastError());

	if ((con = malloc(sizeof(struct agent_connection))) == NULL)
		fatal("failed to alloc");

	memset(con, 0, sizeof(struct agent_connection));
	con->pipe_handle = pipe;
	if (CreateIoCompletionPort(pipe, ioc_port, (ULONG_PTR)con, 0) != ioc_port)
		fatal("failed to assign pipe to ioc_port");

	/* get client details */
	if (get_con_client_info(con) == -1)
		fatal("failed to retrieve client details");

	agent_connection_on_io(con, 0, &con->ol);
	iocp_work(NULL);
}

void 
agent_initialize_allow_list() {
	/* 
	 * allowed paths for PKCS11 libraries,
	 * attempt to initialize to ProgramFiles and ProgramFiles(x86) by default 
	 * upstream uses /usr/lib/* and /usr/local/lib/* 
	 */
	size_t allowed_len = 0, prog_files_len = 0, prog_files_x86_len = 0;
	char* allowed_path = NULL, *prog_files = NULL, *prog_files_x86 = NULL;

	_dupenv_s(&prog_files, &prog_files_len, "ProgramFiles");
	_dupenv_s(&prog_files_x86, &prog_files_x86_len, "ProgramFiles(x86)");

	if (!prog_files && !prog_files_x86) {
		allowed_providers = xstrdup("");
		return;
	}

	if (prog_files && prog_files_x86) {
		allowed_len = prog_files_len + 3 + prog_files_x86_len + 1;
		allowed_path = xmalloc(allowed_len);
		sprintf_s(allowed_path, allowed_len, "%s\\*,%s", prog_files, prog_files_x86);
		free(prog_files);
		free(prog_files_x86);
	}
	else if (prog_files) {
		allowed_len = prog_files_len;
		allowed_path = prog_files;
	}
	else if (prog_files_x86) {
		allowed_len = prog_files_x86_len;
		allowed_path = prog_files_x86;
	}

	allowed_len += 3; /* for additional characters below */
	allowed_providers = xmalloc(allowed_len);
	sprintf_s(allowed_providers, allowed_len, "%s\\*", allowed_path);

	if (allowed_path) {
		free(allowed_path);
	}
}
