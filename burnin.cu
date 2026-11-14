// Original CUDA workload: no network, filesystem access, shell execution or privileges.
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <chrono>
#include <string>
#define CU(x) do { cudaError_t e=(x); if(e!=cudaSuccess){fprintf(stderr,"CUDA %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e));return 2;} } while(0)
#define BL(x) do { if((x)!=CUBLAS_STATUS_SUCCESS){fprintf(stderr,"CUBLAS failure line %d\n",__LINE__);return 3;} } while(0)
__device__ unsigned long long pattern(unsigned long long i,unsigned long long seed){
    unsigned long long x=i+seed*0x9e3779b97f4a7c15ULL;
    x=(x^(x>>30))*0xbf58476d1ce4e5b9ULL;
    x=(x^(x>>27))*0x94d049bb133111ebULL;
    return x^(x>>31);
}
__global__ void memory(unsigned long long* p,size_t n,unsigned long long seed,bool verify,unsigned long long* errors){
    for(size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x;i<n;i+=(size_t)blockDim.x*gridDim.x){
        auto expected=pattern(i,seed);
        if(verify){if(p[i]!=expected) atomicAdd(errors,1ULL);}else p[i]=expected;
    }
}
__global__ void matrices(float* a,float* b,size_t n,int side){
    for(size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x;i<n;i+=(size_t)blockDim.x*gridDim.x){a[i]=1.0f;b[i]=(float)((int)((i/side)%7)-3)/8.0f;}
}
__global__ void check_matrix(float* c,size_t n,int side,unsigned long long* errors){
    for(size_t i=blockIdx.x*(size_t)blockDim.x+threadIdx.x;i<n;i+=(size_t)blockDim.x*gridDim.x){
        float expected=side*((float)((int)((i/side)%7)-3)/8.0f);
        if(!isfinite(c[i])||fabsf(c[i]-expected)>0.001f) atomicAdd(errors,1ULL);
    }
}
__global__ void corrupt(unsigned long long* p){if(threadIdx.x==0&&blockIdx.x==0)p[0]^=1ULL;}
int main(int argc,char** argv){
    if(argc<3||argc>4){fprintf(stderr,"usage: burnin GiB seconds [--inject-error]\n");return 64;}
    char *end=nullptr;double gib=strtod(argv[1],&end);if(*end||!std::isfinite(gib)||gib<0.125||gib>90)return 64;
    double seconds=strtod(argv[2],&end);if(*end||!std::isfinite(seconds)||seconds<1||seconds>86400)return 64;
    bool inject=argc==4;if(inject&&std::string(argv[3])!="--inject-error")return 64;
    size_t bytes=(size_t)(gib*1073741824.0),n=bytes/8;
    unsigned long long *p,*errors;float *a,*b,*c;const int side=8192;size_t mn=(size_t)side*side;
    CU(cudaSetDevice(0));CU(cudaMalloc(&p,bytes));CU(cudaMalloc(&errors,8));CU(cudaMalloc(&a,mn*4));CU(cudaMalloc(&b,mn*4));CU(cudaMalloc(&c,mn*4));
    cublasHandle_t handle;BL(cublasCreate(&handle));BL(cublasSetMathMode(handle,CUBLAS_TF32_TENSOR_OP_MATH));
    matrices<<<4096,256>>>(a,b,mn,side);CU(cudaGetLastError());CU(cudaDeviceSynchronize());
    auto start=std::chrono::steady_clock::now();unsigned long long cycle=0,host_errors=0;float alpha=1,beta=0;
    setvbuf(stdout,nullptr,_IOLBF,0);printf("START bytes=%zu matrix=%d injection=%d\n",bytes,side,inject);
    do {
        cycle++;CU(cudaMemset(errors,0,8));
        memory<<<4096,256>>>(p,n,cycle,false,errors);CU(cudaGetLastError());
        if(inject){corrupt<<<1,1>>>(p);CU(cudaGetLastError());}
        memory<<<4096,256>>>(p,n,cycle,true,errors);CU(cudaGetLastError());
        CU(cudaDeviceSynchronize());CU(cudaMemcpy(&host_errors,errors,8,cudaMemcpyDeviceToHost));
        if(host_errors){fprintf(stderr,"FAIL memory cycle=%llu mismatches=%llu\n",cycle,host_errors);return 4;}
        for(int repeat=0;repeat<128;repeat++)BL(cublasSgemm(handle,CUBLAS_OP_N,CUBLAS_OP_N,side,side,side,&alpha,a,side,b,side,&beta,c,side));
        check_matrix<<<4096,256>>>(c,mn,side,errors);CU(cudaGetLastError());CU(cudaDeviceSynchronize());
        CU(cudaMemcpy(&host_errors,errors,8,cudaMemcpyDeviceToHost));
        if(host_errors){fprintf(stderr,"FAIL compute cycle=%llu mismatches=%llu\n",cycle,host_errors);return 5;}
        printf("PASS cycle=%llu elapsed=%.3f bytes_verified=%zu gemms=128\n",cycle,std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count(),bytes);
    }while(std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()<seconds);
    BL(cublasDestroy(handle));CU(cudaFree(c));CU(cudaFree(b));CU(cudaFree(a));CU(cudaFree(errors));CU(cudaFree(p));
    printf("COMPLETE cycles=%llu\n",cycle);return 0;
}
