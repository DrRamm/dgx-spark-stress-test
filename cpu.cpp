// Original CPU workload: fixed private buffers, checked integer patterns, no I/O except stdout.
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <thread>
#include <vector>
#include <string>
static std::atomic<bool> stop{false};
static std::atomic<unsigned long long> cycles{0},errors{0};
static_assert(std::atomic<bool>::is_always_lock_free,"signal stop requires lock-free atomic");
static void halt(int){stop.store(true,std::memory_order_relaxed);}
static uint64_t pattern(uint64_t x){x=(x^(x>>30))*0xbf58476d1ce4e5b9ULL;x=(x^(x>>27))*0x94d049bb133111ebULL;return x^(x>>31);}
int main(int argc,char**argv){
    if(argc<2||argc>3)return 64;
    char* end=nullptr;long seconds=strtol(argv[1],&end,10);if(*end||seconds<1||seconds>86400)return 64;
    bool inject=argc==3;if(inject&&std::string(argv[2])!="--inject-error")return 64;
    signal(SIGTERM,halt);signal(SIGINT,halt);setvbuf(stdout,nullptr,_IOLBF,0);
    auto started=std::chrono::steady_clock::now();unsigned count=std::thread::hardware_concurrency();if(!count||count>256)return 64;
    printf("START threads=%u bytes_per_thread=33554432\n",count);
    std::vector<std::thread> threads;
    for(unsigned t=0;t<count;t++)threads.emplace_back([=]{
        size_t n=32*1024*1024/sizeof(uint64_t);std::unique_ptr<uint64_t[]> storage(new uint64_t[n]);volatile uint64_t* p=storage.get();uint64_t seed=t+1;
        while(!stop.load(std::memory_order_relaxed)){
            for(size_t i=0;i<n;i++)p[i]=pattern(i+seed);
            if(inject&&t==0)p[0]^=1;
            for(size_t i=0;i<n;i++)if(p[i]!=pattern(i+seed)){errors++;stop=true;break;}
            cycles++;seed+=count;
        }
    });
    while(!stop.load()&&std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count()<seconds){
        std::this_thread::sleep_for(std::chrono::seconds(1));
        printf("PROGRESS cycles=%llu errors=%llu\n",cycles.load(),errors.load());
    }
    stop=true;for(auto&thread:threads)thread.join();
    printf("COMPLETE cycles=%llu errors=%llu\n",cycles.load(),errors.load());
    return errors.load()?4:0;
}
