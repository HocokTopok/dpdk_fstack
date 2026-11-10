//////////////////////////////////////////////////////////////////////////////////////////////

// Ubuntu (also macOS): ordinary blocking TCP echo client

//////////////////////////////////////////////////////////////////////////////////////////////

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

//////////////////////////////////////////////////////////////////////////////////////////////

namespace {

[[noreturn]] void fail(const char* operation)
{
  const int error = errno;
  throw std::runtime_error(std::string(operation) + ": " + std::strerror(error));
}

} // namespace

//////////////////////////////////////////////////////////////////////////////////////////////

int main()
{
  int fd = -1;

  try
  {
    sockaddr_in server{};
    const char* server_ip = std::getenv("SERVER_IP");

    if (server_ip == nullptr || inet_pton(AF_INET, server_ip, &server.sin_addr) != 1)
    {
      throw std::runtime_error("Set SERVER_IP to the Mac IPv4 address before starting the client.");
    }

    server.sin_family = AF_INET;
    server.sin_port = htons(3333);
    std::signal(SIGPIPE, SIG_IGN);

    fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0)
    {
      fail("socket");
    }

    const char* interface = std::getenv("CLIENT_INTERFACE");

    if (interface != nullptr && *interface != '\0')
    {
#ifdef __linux__
      if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, interface,
        static_cast<socklen_t>(std::strlen(interface) + 1)) < 0)
      {
        fail("SO_BINDTODEVICE");
      }
      std::cout << "Bound to interface: " << interface << '\n';
#else
      throw std::runtime_error("CLIENT_INTERFACE requires Linux");
#endif
    }

    const int enabled = 1;
    const timeval timeout{30, 0};

    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0)
    {
      fail("setsockopt");
    }

    std::cout << "Connecting to " << server_ip << ":3333\n";

    if (connect(fd, reinterpret_cast<const sockaddr*>(&server), sizeof(server)) < 0)
    {
      fail("connect");
    }

    sockaddr_in local{};
    socklen_t local_size = sizeof(local);

    if (getsockname(fd, reinterpret_cast<sockaddr*>(&local), &local_size) < 0)
    {
      fail("getsockname");
    }

    std::array<char, INET_ADDRSTRLEN> local_ip{};

    if (inet_ntop(AF_INET, &local.sin_addr, local_ip.data(), local_ip.size()) == nullptr)
    {
      fail("inet_ntop");
    }

    std::cout << "Local IP: " << local_ip.data() << '\n';
    std::cout << "Connected. Echoing data until the server closes the connection.\n";

    std::array<char, 4096> buffer{};
    std::size_t echoes = 0;

    while (true)
    {
      const auto received = recv(fd, buffer.data(), buffer.size(), 0);

      if (received == 0)
      {
        break;
      }

      if (received < 0)
      {
        if (errno == EINTR)
        {
          continue;
        }
        fail("recv (30-second idle timeout)");
      }

      const auto size = static_cast<std::size_t>(received);
      std::size_t offset = 0;

      while (offset < size)
      {
        const auto sent = send(fd, buffer.data() + offset, size - offset, 0);

        if (sent < 0)
        {
          if (errno == EINTR)
          {
            continue;
          }
          fail("send");
        }

        if (sent == 0)
        {
          throw std::runtime_error("send returned zero before the echo was complete");
        }

        const auto end = offset + static_cast<std::size_t>(sent);
        echoes += static_cast<std::size_t>(std::count(
            buffer.data() + offset, buffer.data() + end, '!'));
        offset = end;
      }
    }

    if (echoes == 0)
    {
      throw std::runtime_error("Server closed without sending any messages");
    }

    close(fd);

    std::cout << "Echoed messages (including warmup): " << echoes << '\n';

    return EXIT_SUCCESS;
  }
  catch (const std::exception& error)
  {
    if (fd >= 0)
    {
      close(fd);
    }
    std::cerr << "Error: " << error.what() << '\n';

    return EXIT_FAILURE;
  }
}

//////////////////////////////////////////////////////////////////////////////////////////////
