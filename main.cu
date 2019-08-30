#include <iostream>
#include <math.h>
#include <fstream>

// #define RANDOM_WALK

typedef struct {
    float x;
    float y;
    float horizontal_speed;
    float vertical_speed;
    uint seed;
} Particle;

typedef struct {
    int x;
    int y;
} Veci2D;

const float radius = 2.0f;
const int ceil_radius = (int)radius + ((((float)(int)radius) < radius) ? 1 : 0);
const float max_speed = 3.0f;
const int particle_count = 4096 * 8;

const int grid_size = 1024 * 8;
const int grid_width = grid_size;
const int grid_height = grid_size;

__device__ int grid[grid_height][grid_width];
__constant__ Veci2D* circle_indices;
__constant__ int circle_indices_length;
__device__ int border_left;
__device__ int border_right;
__device__ int border_top;
__device__ int border_bottom;

void VecAdd();
void simulate();
void tick(Particle* particles, int tick_count);
__device__ int random_int(int min, int max, uint seed);

#define print(message) std::cout << message << std::endl

int main() {
    print("starting");
    simulate();
    print("done");
}

// checks for cuda errors
// could be improved
void cuda_error() {
    auto result = cudaGetLastError();
    if (result != cudaSuccess) {
        std::cout << "error: " << result << std::endl;
    }
    else {
        std::cout << "success" << std::endl;
    }
}

// sets the grid values to -1
__global__ void init_grid_negative() {
    grid[blockIdx.y * blockDim.y + threadIdx.y][blockIdx.x * blockDim.x + threadIdx.x] = -1;
}

// sets the center of the grid to 0
__global__ void init_grid_center() {
    grid[grid_height / 2][grid_width / 2] = 0;
    border_top = grid_height / 2;
    border_bottom = grid_height / 2;
    border_left = grid_width / 2;
    border_right = grid_width / 2;
}

// outputs the grid (and its widht/height) to a file
void output_grid() {
    // get grid from GPU memory
    size_t mem_size = sizeof(int) * grid_height * grid_width;
    int* host_grid = (int*)malloc(mem_size);
    cudaMemcpyFromSymbol(host_grid, grid, mem_size, 0, cudaMemcpyDeviceToHost);

    // create file
    std::ofstream output_file;
    output_file.open("grid_output.bin", std::ios::binary);
    if(output_file.is_open()) {
        print("output_file is open");
    }

    // output to file
    const int ints[2] = {grid_width, grid_height};
    output_file.write((const char*) &ints, sizeof(int) * 2);
    //output_file.write((const char*) &grid_height, sizeof(int));
    output_file.write((const char*) host_grid, mem_size);


    // std::cout << std::endl << std::endl << "[";
    // for(int y = 0; y < grid_height; y++) {
    //     std::cout << "\"";
    //     for(int x = 0; x < grid_width; x++) {
    //         int value_at_xy = *(host_grid + x + y * grid_width);
    //         // std::cout << value_at_xy << ",";
    //         //std::cout << (value_at_xy >= 0) ? "1" : "0";
    //         print(value_at_xy);
    //     } 
    //     std::cout << "\"," << std::endl;
    // }
    // std::cout << "]" << std::endl << std::endl;
    
    // clean up
    output_file.close();
    delete host_grid;
}

__device__ uint hash(uint x) {
    const uint seed = 1324567967 + 2;
    x += seed;
    x = ((x >> 16) ^ x) * seed;
    x = ((x >> 16) ^ x) * seed;
    x = (x >> 16) ^ x;
    return x;
}

// returns an int in the range [min, max) based on seed
__device__ int random_int(int min, int max, uint seed) {
    uint random = hash(seed);
    random %= max - min;
    
    return (int)random + min;
}

// returns a float in the range [0, 1) based on seed;
__device__ float random_float(uint seed) {
    const int max = 10000000;
    int base = random_int(0, max, seed);

    return (float)base / (float)max;
}

__device__ void randomize_speed(Particle* particle, int direction_seed, int speed_seed) {
    float direction = M_PI * 2.0f * random_float(direction_seed);
    float speed = random_float(speed_seed) * max_speed;

    particle->vertical_speed = cosf(direction) * speed;
    particle->horizontal_speed = sinf(direction) * speed;
}

// randomizes all fields of the particle
__device__ void randomize_particle(Particle* particle) {
    uint seed = particle->seed;
    int center_width = border_right - border_left;
    int center_height = border_bottom - border_top;

    particle->x = random_int(0, grid_width - center_width, seed + 0);
    particle->y = random_int(0, grid_height - center_height, seed + 1);
    if(particle->x > border_left) {
        particle->x += center_width;
    }
    if(particle->y > border_top) {
        particle->y += center_height;
    }

    randomize_speed(particle, seed + 2, seed + 3);

    particle->seed = hash(seed);
}

// initializes the particle
__global__ void init_particles(Particle* particles) {
    int i = threadIdx.x + blockIdx.x * blockDim.x; // particle index in the particles array
    Particle* particle = particles + i;
    particle->seed = (uint)i * 4;
    randomize_particle(particle);
}

// prints border_left, border_right, border_top and border_bottom to stdio
void print_boundaries() {
    int left, right, top, bottom;

    cudaMemcpyFromSymbol(&left, border_left, sizeof(int));
    cudaMemcpyFromSymbol(&right, border_right, sizeof(int));
    cudaMemcpyFromSymbol(&top, border_top, sizeof(int));
    cudaMemcpyFromSymbol(&bottom, border_bottom, sizeof(int));
    print(left << ", " << right << ", " << top << ", " << bottom);
}

void simulate() {
    // initialize grid
    dim3 threadsPerBlock(16, 16);
    dim3 blocks(grid_width / threadsPerBlock.x, grid_height / threadsPerBlock.y);
    init_grid_negative<<<blocks, threadsPerBlock>>>();
    init_grid_center<<<1, 1>>>();

    // initialize particles
    size_t mem_size = particle_count * sizeof(Particle);
    Particle* particles;
    cudaMalloc(&particles, mem_size);
    const int particle_threads_per_block = 256;
    const int particle_blocks = particle_count / particle_threads_per_block;

    cuda_error();
    init_particles<<<particle_blocks, particle_threads_per_block>>>(particles);
    // done intializing particles

    print_boundaries();
    cuda_error();

    int tick_count = 0;
    for(int i = 0; true; i++) {
        tick(particles, ++tick_count);

      
        int left, right, top, bottom;

        cudaMemcpyFromSymbol(&left, border_left, sizeof(int));
        cudaMemcpyFromSymbol(&right, border_right, sizeof(int));
        cudaMemcpyFromSymbol(&top, border_top, sizeof(int));
        cudaMemcpyFromSymbol(&bottom, border_bottom, sizeof(int));

        if(i % 100 == 0) {
            print(left << ", " << right << ", " << top << ", " << bottom);
        }
        const int margin = 50;
        if(left < margin || right > grid_width - margin || top < margin || bottom > grid_height - margin) {
            break;
        }
    }
    cuda_error();
    output_grid();

    cudaFree(particles);
}

__global__ void particle_step(Particle* particles, int tick_count) {
    int i = blockIdx.x * blockDim.x + threadIdx.x; // particle index in the particles array
    Particle* particle = particles + i;
    
    #ifdef RANDOM_WALK
    // randomize direction and speed
    randomize_speed(particle, particle->seed, particle->seed + 1);
    particle->seed = hash(particle->seed);
    #endif

    // move particle
    particle->x += particle->horizontal_speed;
    particle->y += particle->vertical_speed;

    // check bounds
    if(particle->x - radius <= 0.0f) {
        particle->x = 0.01f + radius;
        particle->horizontal_speed *= -1.0f;
    }
    else if(particle->x + radius >= grid_width) {
        particle->x = grid_width - 0.01f - radius;
        particle->horizontal_speed *= -1.0f;
    }
    if(particle->y - radius <= 0.0f) {
        particle->y = 0.01f + radius ;
        particle->vertical_speed *= -1.0f;
    }
    else if(particle->y + radius >= grid_height) {
        particle->y = grid_height - 0.01f - radius;
        particle->vertical_speed *= -1.0f;
    }

    // calculate some variable values to be used later
    const int diameter = ceil_radius * 2;

    int left = (int)(particle->x - radius);
    int top = (int)(particle->y - radius);
    float modulo_x = fmod(particle->x, 1.0f);
    float modulo_y = fmod(particle->y, 1.0f);
    bool looping = true;

    for(int dx = -ceil_radius; dx <= ceil_radius && looping; dx++) {
        for(int dy = -ceil_radius; dy <= ceil_radius && looping; dy++) {
            // calculate distance from center of the particle
            float distance_x = -dx + modulo_x;
            float distance_y = -dy + modulo_y;

            if(distance_x * distance_x + distance_y * distance_y < radius * radius) {
                // position is within radius of the center
                if(grid[(int)(particle->y - distance_y)][(int)(particle->x - distance_x)] >= 0) {
                    // hit another particle

                    for(int dx2 = -ceil_radius; dx2 <= ceil_radius; dx2++) {
                        for(int dy2 = -ceil_radius; dy2 <= ceil_radius; dy2++) {
                            // calculate distance from center of the particle
                            float distance_x2 = -dx2 + modulo_x;
                            float distance_y2 = -dy2 + modulo_y;
                
                            if(distance_x2 * distance_x2 + distance_y2 * distance_y2 < radius * radius) {
                                // calculate position in grid
                                int absolute_x = (int)(particle->x - distance_x2);
                                int absolute_y = (int)(particle->y - distance_y2);
                    
                                // if the absolute_x/y are within the grid
                                if(absolute_x >= 0 && absolute_x < grid_width && absolute_y >= 0 && absolute_y < grid_height) {
                                    // set the grid to being hit
                                    grid[absolute_y][absolute_x] = tick_count;

                                    /*
                                        Because the program writes and reads from the same grid in a single tick,
                                        the algorithm isn't completely deterministic. I could use two different 
                                        grids and then copy values, but it doesn't feel necessary.
                                    */
                                }
                            }
                        }
                    }
                    
                    atomicMin(&border_left, (int)(particle->x - radius));
                    atomicMax(&border_right, (int)(particle->x + radius));
                    atomicMin(&border_top, (int)(particle->y - radius));
                    atomicMax(&border_bottom, (int)(particle->y + radius));
                    
                    // give the particle a random new position and speed
                    randomize_particle(particle);

                    looping = false;
                    break;
                }
            }
            
        }
    }
}

// perform one tick
void tick(Particle* particles, int tick_count) {
    const int threads_per_block = 32;
    const int blocks = particle_count / threads_per_block;

    particle_step<<<blocks, threads_per_block>>>(particles, tick_count);
}