#ifndef RUNNER_SERIAL_WORKER_H_
#define RUNNER_SERIAL_WORKER_H_

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

// Native VPN operations share process/service handles. Keep them ordered on
// one worker, never on Flutter's platform thread (which also paints Windows).
class SerialWorker {
 public:
  SerialWorker() : thread_([this] { Run(); }) {}
  ~SerialWorker() { Stop(); }
  SerialWorker(const SerialWorker&) = delete;
  SerialWorker& operator=(const SerialWorker&) = delete;

  bool Post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) return false;
      tasks_.push_back(std::move(task));
    }
    ready_.notify_one();
    return true;
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
    }
    ready_.notify_one();
    if (thread_.joinable()) thread_.join();
  }

 private:
  void Run() {
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
        if (tasks_.empty()) return;
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }
      task();
    }
  }
  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};
#endif
