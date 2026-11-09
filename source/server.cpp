// Mac: ordinary TCP server using Boost.Asio, without DPDK. Requires C++17.
// Usage: ./server [measurement_count] [output.csv]
// Example: ./server 1000 fstack_rtt.csv

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <boost/asio.hpp>

namespace {

using Clock = std::chrono::steady_clock;
using Tcp = boost::asio::ip::tcp;

constexpr unsigned short port = 3333;
constexpr std::size_t warmup_count = 100;
constexpr auto interval = std::chrono::milliseconds(10);

struct Measurement {
    std::size_t sequence;
    std::int64_t sent_ns;
    std::int64_t received_ns;
};

std::int64_t elapsed_ns(Clock::time_point time, Clock::time_point origin)
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(time - origin).count();
}

std::vector<Measurement> measure(Tcp::socket& socket, std::size_t count)
{
    std::vector<Measurement> results;
    results.reserve(count);
    boost::asio::streambuf input(256);
    const auto origin = Clock::now();

    for (std::size_t i = 0; i < warmup_count + count; ++i) {
        const auto sequence = std::to_string(i);
        const auto request = sequence + '!';

        const auto sent = Clock::now();
        boost::asio::write(socket, boost::asio::buffer(request));
        boost::asio::read_until(socket, input, '!');
        const auto received = Clock::now();

        std::istream stream(&input);
        std::string response;
        std::getline(stream, response, '!');
        if (response != sequence || input.size() != 0) {
            throw std::runtime_error("Incorrect echo for message " + sequence);
        }

        if (i >= warmup_count) {
            results.push_back({i - warmup_count, elapsed_ns(sent, origin),
                               elapsed_ns(received, origin)});
        }
        // Outside the measured interval; retain the original 10 ms pacing.
        if (i + 1 < warmup_count + count) {
            std::this_thread::sleep_for(interval);
        }
    }
    return results;
}

void save_and_report(const std::vector<Measurement>& results, const std::string& path)
{
    std::ofstream csv(path);
    csv.exceptions(std::ios::failbit | std::ios::badbit);
    // Timestamps are monotonic nanoseconds relative to the test start, not UTC.
    csv << "seq,send_timestamp_ns,recv_timestamp_ns,rtt_ns\n";

    std::vector<std::int64_t> rtts;
    rtts.reserve(results.size());
    long double total = 0;
    for (const auto& result : results) {
        const auto rtt = result.received_ns - result.sent_ns;
        csv << result.sequence << ',' << result.sent_ns << ','
            << result.received_ns << ',' << rtt << '\n';
        rtts.push_back(rtt);
        total += rtt;
    }
    csv.close();
    std::sort(rtts.begin(), rtts.end());

    const auto percentile = [&](std::size_t percent) {
        // Nearest-rank percentile.
        return rtts[(rtts.size() * percent + 99) / 100 - 1] / 1000.0;
    };
    const auto middle = rtts.size() / 2;
    const double median = rtts.size() % 2 != 0
        ? rtts[middle] / 1000.0
        : (rtts[middle - 1] / 2.0 + rtts[middle] / 2.0) / 1000.0;

    std::cout << std::fixed << std::setprecision(3)
              << "Measurements: " << results.size() << " (warmup excluded)\n"
              << "RTT, microseconds:\n"
              << "  min:    " << rtts.front() / 1000.0 << '\n'
              << "  mean:   " << total / results.size() / 1000.0L << '\n'
              << "  median: " << median << '\n'
              << "  p95:    " << percentile(95) << '\n'
              << "  p99:    " << percentile(99) << '\n'
              << "  max:    " << rtts.back() / 1000.0 << '\n'
              << "CSV: " << path << '\n';
}

} // namespace

int main(int argc, char** argv)
{
    try {
        if (argc > 3) {
            throw std::runtime_error("Usage: ./server [measurement_count] [output.csv]");
        }
        std::size_t count = 1000;
        if (argc >= 2) {
            const std::string argument = argv[1];
            if (argument.empty() || argument.find_first_not_of("0123456789") != std::string::npos) {
                throw std::runtime_error("Measurement count must be an integer from 1 to 1000000");
            }
            const auto value = std::stoull(argument);
            if (value == 0 || value > 1000000) {
                throw std::runtime_error("Measurement count must be from 1 to 1000000");
            }
            count = static_cast<std::size_t>(value);
        }
        const std::string path = argc >= 3 ? argv[2] : "server_timestamps.csv";

        boost::asio::io_context io;
        Tcp::acceptor acceptor(io);
        acceptor.open(Tcp::v4());
        acceptor.set_option(Tcp::acceptor::reuse_address(true));
        acceptor.bind(Tcp::endpoint(Tcp::v4(), port));
        acceptor.listen(1);

        std::cout << "Listening on TCP port " << port << ". Waiting for the Ubuntu client..." << std::endl;
        Tcp::socket socket(io);
        acceptor.accept(socket);
        socket.set_option(Tcp::no_delay(true));
        std::cout << "Client: " << socket.remote_endpoint()
                  << "; warmup: " << warmup_count << "; measurements: " << count << std::endl;

        const auto results = measure(socket, count);
        // Close after the last echo has arrived; the client then receives EOF.
        socket.shutdown(Tcp::socket::shutdown_send);
        socket.close();
        save_and_report(results, path);
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
