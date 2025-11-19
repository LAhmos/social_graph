#ifndef THREADPOOL_H
#define THREADPOOL_H

#include <thread>
#include <vector>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <functional>

// Thread pool for reusable worker threads
// Each worker gets a unique worker_id (0 to num_threads-1) directly with no contention
// Tasks are specified as: void task(int worker_id)
// 
// Modes:
// - POOL_MODE: Uses persistent worker threads (default, more efficient)
// - SPAWN_MODE: Spawns a new thread for each request (for comparison/testing)
class ThreadPool {
public:
    enum Mode {
        POOL_MODE,   // Use persistent thread pool
        SPAWN_MODE   // Spawn new thread for each request
    };

private:
    Mode execution_mode;
    std::vector<std::thread> workers;
    std::atomic<bool> stop_flag{false};
    int num_workers;
    
    std::mutex queue_mutex;
    std::condition_variable cv_work_available;
    std::condition_variable cv_work_done;
    
    std::atomic<int> tasks_completed{0};
    std::atomic<bool> work_ready{false};
    std::function<void(int)> current_task;
    int num_tasks_expected = 0;
    std::atomic<int> execution_counter{0};  // Increments with each execute() call
    std::vector<int> worker_last_execution;  // Last execution_counter each worker saw
    
public:
    ThreadPool(int num_threads, Mode mode = POOL_MODE) 
        : num_workers(num_threads), execution_mode(mode) {
        
        // Only create persistent worker threads in POOL_MODE
        if (execution_mode == POOL_MODE) {
            workers.reserve(num_threads);
            worker_last_execution.resize(num_threads, -1);
            
            for (int worker_id = 0; worker_id < num_threads; worker_id++) {
                workers.emplace_back([this, worker_id]() {  // Capture worker_id directly
                    while (true) {
                        std::function<void(int)> task;
                        bool should_execute = false;
                        int current_execution;
                        
                        {
                            std::unique_lock<std::mutex> lock(queue_mutex);
                            cv_work_available.wait(lock, [this, worker_id] {
                                return stop_flag.load() || 
                                       (work_ready.load() && worker_last_execution[worker_id] < execution_counter.load());
                            });
                            
                            if (stop_flag.load()) {
                                return;
                            }
                            
                            // This worker should execute
                            should_execute = true;
                            current_execution = execution_counter.load();
                            worker_last_execution[worker_id] = current_execution;
                            task = current_task;
                        }
                        
                        if (should_execute && task) {
                            // Execute with this worker's ID directly - no contention!
                            task(worker_id);
                            
                            // Signal completion
                            int completed = tasks_completed.fetch_add(1) + 1;
                            if (completed == num_tasks_expected) {
                                // Last thread to finish resets work_ready
                                std::lock_guard<std::mutex> lock(queue_mutex);
                                work_ready.store(false);
                                cv_work_done.notify_one();
                            }
                        }
                    }
                });
            }
        }
    }
    
    ~ThreadPool() {
        if (execution_mode == POOL_MODE) {
            {
                std::lock_guard<std::mutex> lock(queue_mutex);
                stop_flag.store(true);
            }
            cv_work_available.notify_all();
            for (auto& worker : workers) {
                if (worker.joinable()) {
                    worker.join();
                }
            }
        }
    }
    
    // Execute a batch of tasks using the thread pool
    // task: function that takes worker_id as parameter
    // num_tasks: number of logical tasks (usually equals num_workers for load balancing)
    void execute(std::function<void(int)> task, int num_tasks) {
        if (execution_mode == SPAWN_MODE) {
            // SPAWN_MODE: Create a new thread for each task
            std::vector<std::thread> temp_threads;
            temp_threads.reserve(num_tasks);
            
            for (int i = 0; i < num_tasks; i++) {
                temp_threads.emplace_back(task, i);
            }
            
            // Wait for all spawned threads to complete
            for (auto& t : temp_threads) {
                if (t.joinable()) {
                    t.join();
                }
            }
        } else {
            // POOL_MODE: Use persistent worker threads
            {
                std::lock_guard<std::mutex> lock(queue_mutex);
                current_task = task;
                num_tasks_expected = num_tasks;
                tasks_completed.store(0);
                // Increment execution counter so workers know this is a new batch
                execution_counter.fetch_add(1);
                work_ready.store(true);
            }
            
            cv_work_available.notify_all();
            
            // Wait for all tasks to complete
            std::unique_lock<std::mutex> lock(queue_mutex);
            cv_work_done.wait(lock, [this] {
                return !work_ready.load() && tasks_completed.load() >= num_tasks_expected;
            });
            
            current_task = nullptr;
        }
    }
    
    int get_num_workers() const { return num_workers; }
};

#endif // THREADPOOL_H
