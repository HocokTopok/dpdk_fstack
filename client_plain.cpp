// Ubuntu (also macOS): ordinary blocking TCP echo client. Requires C++17.
// Build: g++ -std=c++17 -O2 -Wall -Wextra client_plain.cpp -o client_plain
// Run: SERVER_IP=192.168.1.104 ./client_plain
// Uses the same server.cpp and echo protocol as the F-Stack client.

#include <algorithm>
#include <array>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>

#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace {

[[noreturn]] void fail(const char* operation)
{
    const int error = errno;
    throw std::runtime_error(std::string(operation) + ": " + std::strerror(error));
}

} // namespace

int main()
{
    int fd = -1;
    try {
        sockaddr_in server{};
        const char* server_ip = std::getenv("SERVER_IP");
        if (server_ip == nullptr || inet_pton(AF_INET, server_ip, &server.sin_addr) != 1) {
            throw std::runtime_error("Set SERVER_IP to the Mac IPv4 address before starting the client.");
        }
        server.sin_family = AF_INET;
        server.sin_port = htons(3333);
        std::signal(SIGPIPE, SIG_IGN);

        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            fail("socket");
        }

        const int enabled = 1;
        const timeval timeout{30, 0};
        if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled)) < 0 ||
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0 ||
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) {
            fail("setsockopt");
        }

        std::cout << "Connecting to " << server_ip << ":3333\n";
        if (connect(fd, reinterpret_cast<const sockaddr*>(&server), sizeof(server)) < 0) {
            fail("connect");
        }
        std::cout << "Connected. Echoing data until the server closes the connection.\n";

        std::array<char, 4096> buffer{};
        std::size_t echoes = 0;
        while (true) {
            const auto received = recv(fd, buffer.data(), buffer.size(), 0);
            if (received == 0) {
                break;
            }
            if (received < 0) {
                if (errno == EINTR) {
                    continue;
                }
                fail("recv (30-second idle timeout)");
            }

            // Return every received byte, including when send() writes only part.
            const auto size = static_cast<std::size_t>(received);
            std::size_t offset = 0;
            while (offset < size) {
                const auto sent = send(fd, buffer.data() + offset, size - offset, 0);
                if (sent < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    fail("send");
                }
                if (sent == 0) {
                    throw std::runtime_error("send returned zero before the echo was complete");
                }
                const auto end = offset + static_cast<std::size_t>(sent);
                echoes += static_cast<std::size_t>(std::count(
                    buffer.data() + offset, buffer.data() + end, '!'));
                offset = end;
            }
        }

        if (echoes == 0) {
            throw std::runtime_error("Server closed without sending any messages");
        }
        close(fd);
        std::cout << "Echoed messages (including warmup): " << echoes << '\n';
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        if (fd >= 0) {
            close(fd);
        }
        std::cerr << "Error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
