#include "../runner/serial_worker.h"
#include <atomic>
#include <chrono>
#include <future>
#include <iostream>
#include <stdexcept>
#include <vector>
using namespace std::chrono_literals;
void require(bool value, const char* why) { if (!value) throw std::runtime_error(why); }
int main() {
  const auto caller = std::this_thread::get_id();
  std::promise<void> entered, release, done;
  auto release_future = release.get_future().share();
  std::atomic<bool> second_started{false};
  std::vector<int> order;
  SerialWorker worker;
  require(worker.Post([&] {
    require(std::this_thread::get_id() != caller, "VPN operation ran on caller/UI thread");
    order.push_back(1); entered.set_value(); release_future.wait(); order.push_back(2);
  }), "first operation rejected");
  require(entered.get_future().wait_for(2s) == std::future_status::ready, "worker did not start");
  require(worker.Post([&] { second_started = true; order.push_back(3); done.set_value(); }),
          "queued disconnect rejected");
  // The UI caller is still executing while a long native start is blocked.
  require(!second_started.load(), "disconnect raced with pending connect");
  release.set_value();
  require(done.get_future().wait_for(2s) == std::future_status::ready, "queue failed to drain");
  worker.Stop();
  require(order == std::vector<int>({1, 2, 3}), "native operations were reordered");
  require(!worker.Post([] {}), "shutdown still accepts VPN operations");
  std::cout << "PASS: nonblocking caller, separate worker, FIFO, shutdown gate\n";
}
