// Ubuntu: TCP echo client using F-Stack + DPDK. Requires C++17.
// Set SERVER_IP to the IPv4 address of the Mac.
// Pass --conf, --proc-type and --proc-id to F-Stack as before.

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>

#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#include <sys/select.h>

extern "C" {
#include <ff_api.h>
}

namespace {

using Clock = std::chrono::steady_clock;
volatile std::sig_atomic_t stop_requested = 0;

void request_stop(int)
{
    stop_requested = 1;
}

struct Client {
    int socket = -1;
    sockaddr_in server{};
    bool connecting = false;
    bool connected = false;
    int exit_code = EXIT_SUCCESS;
    std::array<char, 4096> buffer{};
    std::size_t size = 0;
    std::size_t offset = 0;
    std::size_t echoes = 0;
    Clock::time_point last_activity = Clock::now();
};

void stop(Client& client)
{
    // ff_close may send a TCP FIN and must run before ff_run releases DPDK resources.
    if (client.socket >= 0) {
        const int socket = client.socket;
        client.socket = -1;
        if (ff_close(socket) < 0) {
            std::cerr << "ff_close: " << std::strerror(errno) << '\n';
            client.exit_code = EXIT_FAILURE;
        }
    }
    ff_stop_run();
}

int fail(Client& client, const char* operation, int error = errno)
{
    std::cerr << operation << ": " << std::strerror(error) << '\n';
    client.exit_code = EXIT_FAILURE;
    stop(client);
    return -1;
}

int loop(void* argument)
{
    auto& client = *static_cast<Client*>(argument);

    if (stop_requested) {
        client.exit_code = EXIT_FAILURE;
        stop(client);
        return 0;
    }

    if (Clock::now() - client.last_activity > std::chrono::seconds(30)) {
        return fail(client, "Connection/idle timeout", ETIMEDOUT);
    }

    if (!client.connected) {
        if (!client.connecting) {
            const int result = ff_connect(
                client.socket,
                reinterpret_cast<const linux_sockaddr*>(&client.server),
                sizeof(client.server));

            if (result == 0) {
                client.connected = true;
            } else if (errno == EINPROGRESS || errno == EALREADY || errno == EINTR) {
                client.connecting = true;
                return 0;
            } else {
                return fail(client, "ff_connect");
            }
        } else {
            // Poll completion without blocking the F-Stack packet-processing loop.
            fd_set writable;
            FD_ZERO(&writable);
            FD_SET(client.socket, &writable);
            timeval timeout{};
            const int ready = ff_select(
                client.socket + 1, nullptr, &writable, nullptr, &timeout);

            if (ready < 0) {
                return errno == EINTR ? 0 : fail(client, "ff_select");
            }
            if (ready == 0) {
                return 0;
            }

            int error = 0;
            socklen_t length = sizeof(error);
            if (ff_getsockopt(client.socket, SOL_SOCKET, SO_ERROR, &error, &length) < 0) {
                return fail(client, "ff_getsockopt");
            }
            if (error != 0) {
                return fail(client, "TCP connect", error);
            }
            client.connected = true;
        }

        client.last_activity = Clock::now();
        std::cout << "Connected. Echoing data until the server closes the connection.\n";
    }

    // Do not overwrite the buffer until every byte has been accepted for sending.
    if (client.offset == client.size) {
        const auto received = ff_recv(
            client.socket, client.buffer.data(), client.buffer.size(), 0);

        if (received == 0) {
            if (client.echoes == 0) {
                return fail(client, "Server closed without sending any messages", EPROTO);
            }
            // The server closes only after receiving its final echo.
            stop(client);
            return 0;
        }
        if (received < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                return 0;
            }
            return fail(client, "ff_recv");
        }

        client.size = static_cast<std::size_t>(received);
        client.offset = 0;
        client.last_activity = Clock::now();
    }

    // Echo bytes directly: TCP fragmentation does not change the message content.
    const auto sent = ff_send(
        client.socket, client.buffer.data() + client.offset,
        client.size - client.offset, 0);

    if (sent < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            return 0;
        }
        return fail(client, "ff_send");
    }
    if (sent > 0) {
        const auto end = client.offset + static_cast<std::size_t>(sent);
        client.echoes += static_cast<std::size_t>(std::count(
            client.buffer.data() + client.offset, client.buffer.data() + end, '!'));
        client.offset = end;
        client.last_activity = Clock::now();
    }
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    std::cout << std::unitbuf;
    Client client;
    const char* server_ip = std::getenv("SERVER_IP");
    if (server_ip == nullptr || inet_pton(AF_INET, server_ip, &client.server.sin_addr) != 1) {
        std::cerr << "Set SERVER_IP to the Mac IPv4 address before starting the client.\n";
        return EXIT_FAILURE;
    }
    client.server.sin_family = AF_INET;
    client.server.sin_port = htons(3333);

    if (ff_init(argc, argv) < 0) {
        std::cerr << "ff_init failed. Check the F-Stack configuration and DPDK startup log.\n";
        return EXIT_FAILURE;
    }

    std::signal(SIGINT, request_stop);
    std::signal(SIGTERM, request_stop);
    std::signal(SIGPIPE, SIG_IGN);

    client.socket = ff_socket(AF_INET, SOCK_STREAM, 0);
    if (client.socket < 0) {
        std::cerr << "ff_socket: " << std::strerror(errno) << '\n';
        return EXIT_FAILURE;
    }

    int enabled = 1;
    if (client.socket >= FD_SETSIZE) {
        std::cerr << "Socket descriptor exceeds the ff_select limit.\n";
        ff_close(client.socket);
        return EXIT_FAILURE;
    }
    if (ff_ioctl(client.socket, FIONBIO, &enabled) < 0 ||
        ff_setsockopt(client.socket, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled)) < 0) {
        std::cerr << "Socket setup: " << std::strerror(errno) << '\n';
        ff_close(client.socket);
        return EXIT_FAILURE;
    }

    std::cout << "Connecting to " << server_ip << ":3333\n";
    client.last_activity = Clock::now();
    ff_run(loop, &client);
    if (client.socket >= 0) {
        std::cerr << "F-Stack loop returned before socket shutdown\n";
        return EXIT_FAILURE;
    }

    std::cout << "Echoed messages (including warmup): " << client.echoes << '\n';
    return client.exit_code;
}
