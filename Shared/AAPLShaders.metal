/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Metal shaders used for this sample
*/

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Include header shared between this Metal shader code and C code executing Metal API commands

#import "AAPLShaderTypes.h"

// Vertex shader outputs and per-fragmeht inputs.  Includes clip-space position and vertex outputs
//  interpolated by rasterizer and fed to each fragment genterated by clip-space primitives.
typedef struct
{
    // The [[position]] attribute qualifier of this member indicates this value is the clip space
    //   position of the vertex wen this structure is returned from the vertex shader
    float4 clipSpacePosition [[position]];

    // Since this member does not have a special attribute qualifier, the rasterizer will
    //   interpolate its value with values of other vertices making up the triangle and
    //   pass that interpolated value to the fragment shader for each fragment in that triangle;
    float2 textureCoordinate;

} RasterizerData;

// Iterate state

typedef struct
{
  // 16 bit field that contains the number of bits read for a given block
  ushort numBitsRead;
} IterateState;

typedef struct {
  uint8_t symbol;
  uint8_t bitWidth;
} HuffLookupSymbol;

// Vertex Function
vertex RasterizerData
vertexShader(uint vertexID [[ vertex_id ]],
             constant AAPLVertex *vertexArray [[ buffer(AAPLVertexInputIndexVertices) ]])
{
    RasterizerData out;

    // Index into our array of positions to get the current vertex
    //   Our positons are specified in pixel dimensions (i.e. a value of 100 is 100 pixels from
    //   the origin)
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
  
    // THe output position of every vertex shader is in clip space (also known as normalized device
    //   coordinate space, or NDC).   A value of (-1.0, -1.0) in clip-space represents the
    //   lower-left corner of the viewport wheras (1.0, 1.0) represents the upper-right corner of
    //   the viewport.

    out.clipSpacePosition.xy = pixelSpacePosition;
  
    // Set the z component of our clip space position 0 (since we're only rendering in
    //   2-Dimensions for this sample)
    out.clipSpacePosition.z = 0.0;

    // Set the w component to 1.0 since we don't need a perspective divide, which is also not
    //   necessary when rendering in 2-Dimensions
    out.clipSpacePosition.w = 1.0;

    // Pass our input textureCoordinate straight to our output RasterizerData.  This value will be
    //   interpolated with the other textureCoordinate values in the vertices that make up the
    //   triangle.
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    out.textureCoordinate.y = 1.0 - out.textureCoordinate.y;
    
    return out;
}

// Fill texture with gradient from green to blue as Y axis increases from origin at top left

fragment float4
fragmentFillShader1(RasterizerData in [[stage_in]],
                   float4 framebuffer [[color(0)]])
{
  return float4(0.0, (1.0 - in.textureCoordinate.y) * framebuffer.x, in.textureCoordinate.y * framebuffer.x, 1.0);
}

fragment float4
fragmentFillShader2(RasterizerData in [[stage_in]])
{
  return float4(0.0, 1.0 - in.textureCoordinate.y, in.textureCoordinate.y, 1.0);
}

// Fragment function
fragment float4
samplingPassThroughShader(RasterizerData in [[stage_in]],
               texture2d<half, access::sample> inTexture [[ texture(AAPLTextureIndexes) ]])
{
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  
  return float4(inTexture.sample(s, in.textureCoordinate));
  
}

// huffman decoding kernel

// 4x4 with dim = 2
//
// 0 1 4 5
// 2 3 6 7
// 8 9 C D
// A B E F

// Encoded as streams:
//
// s0: 0 4 8 C
// s1: 1 5 9 D
// s2: 2 6 A E
// s3: 3 7 B F

// Each independent block can now be processed
// in terms of the offset into the stream.
//
// 0 1
// 2 3

kernel void
huffComputeKernel(texture2d<half, access::write>  wTexture  [[texture(0)]],
#if defined(HUFF_EMIT_MULTIPLE_DEBUG_TEXTURES)
                  texture2d<half, access::write>  debugPixelBlockiTexture  [[texture(1)]],
                  texture2d<half, access::write>  debugRootBitOffsetTexture  [[texture(2)]],
                  texture2d<half, access::write>  debugCurrentBitOffsetTexture  [[texture(3)]],
                  texture2d<half, access::write>  debugBitWidthTexture  [[texture(4)]],
                  texture2d<half, access::write>  debugBitPatternTexture  [[texture(5)]],
#endif // HUFF_EMIT_MULTIPLE_DEBUG_TEXTURES
                  device IterateState *iterPtr [[ buffer(AAPLComputeBufferIter) ]],
                  const device uint32_t *blockStartBitOffsetsPtr [[ buffer(AAPLComputeBlockStartBitOffsets) ]],
                  const device uint8_t *huffBuff [[ buffer(AAPLComputeHuffBuff) ]],
                  const device HuffLookupSymbol *huffSymbolTable [[ buffer(AAPLComputeHuffSymbolTable) ]],
                  uint2 gid [[thread_position_in_grid]])
{
  // nop out early when the pixel is outside of bounds
  //if ((gid.x >= wTexture.get_width()) || (gid.y >= wTexture.get_height())) {
  //  return;
  //}

  const ushort blockDim = 2;
  // FIXME: bit and impl for both
  ushort blockX = gid.x / blockDim;
  ushort blockY = gid.y / blockDim;

  //const ushort numWholeBlocksInWidth = (wTexture.get_width() / blockDim);
  //const ushort numBlocksInWidth = numWholeBlocksInWidth + (((wTexture.get_width() % blockDim) != 0) ? 1 : 0);
  //const ushort numBlocksInWidth = numWholeBlocksInWidth;
  const ushort numBlocksInWidth = 1;
  int blocki = (int(blockY) * numBlocksInWidth) + blockX;
  
  // Each range of (blockDim * blockDim) blocks maps to a root value which is added to
  // the calculated blocki for each pixel. For example, a 4x4 input represents 2
  // sets of blocks where each set contains 4 blocks of dim 2x2.
  int blockiGroupRoot = blocki * (blockDim * blockDim);
  
  ushort xOffsetFromBlockStart = gid.x - (blockX * blockDim);
  ushort yOffsetFromBlockStart = gid.y - (blockY * blockDim);
  
  // Square block
  ushort blockIterOffset = (yOffsetFromBlockStart * blockDim) + xOffsetFromBlockStart;
  
  // blocki depends on the block that the output pixel corresponds to
  int blockiThisPixel = blockiGroupRoot + blockIterOffset;

  IterateState iState = iterPtr[blockiThisPixel];
  
  // If the code reached here, then this specific pixel is the one
  // that should be processed next in this render pass.

  const ushort numBitsReadBeforeRenderStep = iState.numBitsRead;
  uint numBitsRead = blockStartBitOffsetsPtr[blockiThisPixel] + numBitsReadBeforeRenderStep;
  
  const ushort numBitsInByte = 8;
  int numBytesRead = int(numBitsRead / numBitsInByte);
  ushort numBitsReadMod8 = (numBitsRead % numBitsInByte);
  
  ushort inputBitPattern = 0;
  ushort b0 = huffBuff[numBytesRead];
  ushort b1 = huffBuff[numBytesRead+1];
  ushort b2 = huffBuff[numBytesRead+2];
  
  // Left shift the already consumed bits off left side of b0
  b0 <<= numBitsReadMod8;
  b0 &= 0xFF;
  inputBitPattern = b0 << 8;
  
  // Left shift the 8 bits in b1 then OR into inputBitPattern
  inputBitPattern |= b1 << numBitsReadMod8;
  
  // Right shift b2 to throw out unused bits
  b2 >>= (8 - numBitsReadMod8);
  inputBitPattern |= b2;
  
  // Lookup 16 bit symbol in left justified table
  
  HuffLookupSymbol hls = huffSymbolTable[inputBitPattern];
  iState.numBitsRead += hls.bitWidth;
  iterPtr[blockiThisPixel] = iState;

  // Write (X,Y) coordinate position for each pixel
  
  //half4 outColor  = half4(0.0h, 0.0h, blockIterOffset/255.0h, 1.0h);
  
  //half4 outColor  = half4(0.0h, 0.0h, blockiThisPixel/255.0h, 1.0h);
  
  //half4 outColor  = half4(0.0h, xOffsetFromBlockStart/255.0h, yOffsetFromBlockStart/255.0h, 1.0h);

  //half4 outColor  = half4(0.0h, 0.0h, blockStartBitOffsetsPtr[blockiThisPixel]/255.0h, 1.0h);
  
  //half4 outColor  = half4(0.0h, 0.0h, hls.bitWidth/255.0h, 1.0h);

//  half4 outColor  = half4(0.0h, 0.0h, numBitsRead/255.0h, 1.0h);

  //half4 outColor  = half4(0.0h, ((inputBitPattern >> 8) & 0xFF)/255.0h, (inputBitPattern&0xFF)/255.0h, 1.0h);
  
  half4 outColor  = half4(0.0h, 0.0h, hls.symbol/255.0h, 1.0h);
  
#if defined(HUFF_EMIT_MULTIPLE_DEBUG_TEXTURES)
  // blocki value that the output pixel (x,y) corresponds to
  {
    const uint blocki = blockiThisPixel;
    half4 color4  = half4(((blocki >> 16) & 0xFF)/255.0h, ((blocki >> 8) & 0xFF)/255.0h, (blocki & 0xFF)/255.0h, 1.0h);
    debugPixelBlockiTexture.write(color4, gid);
  }
  
  // Absolute offset in bits into the huffman buffer based on blocki for each pixel in current block
  {
    const uint numBits = blockStartBitOffsetsPtr[blockiThisPixel];
    half4 color4  = half4(((numBits >> 16) & 0xFF)/255.0h, ((numBits >> 8) & 0xFF)/255.0h, (numBits & 0xFF)/255.0h, 1.0h);
    debugRootBitOffsetTexture.write(color4, gid);
  }

  // Number of bits read from current block before this symbol decode (depends on render step)
  {
    const uint numBits = numBitsReadBeforeRenderStep;
    half4 color4  = half4(((numBits >> 16) & 0xFF)/255.0h, ((numBits >> 8) & 0xFF)/255.0h, (numBits & 0xFF)/255.0h, 1.0h);
    debugCurrentBitOffsetTexture.write(color4, gid);
  }

  // Number of bits wide the currently decode symbol is (depends on render step)
  {
    const uint numBits = hls.bitWidth;
    half4 color4  = half4(((numBits >> 16) & 0xFF)/255.0h, ((numBits >> 8) & 0xFF)/255.0h, (numBits & 0xFF)/255.0h, 1.0h);
    debugBitWidthTexture.write(color4, gid);
  }
  
  // 16 bit bit pattern used as input to the match (depends on render step)
  
  {
    const uint pattern = inputBitPattern;
    half4 color4  = half4(0.0h, ((pattern >> 8) & 0xFF)/255.0h, (pattern & 0xFF)/255.0h, 1.0h);
    debugBitPatternTexture.write(color4, gid);
  }
#endif // HUFF_EMIT_MULTIPLE_DEBUG_TEXTURES
  
  // write out blocki at each pixel
  //half4 outColor  = half4(((blocki >> 16) & 0xFF)/255.0h, ((blocki >> 8) & 0xFF)/255.0h, (blocki & 0xFF)/255.0h, 1.0h);
  
  // write out the number of bits consumed at each pixel
  //uint32_t bOff = blockStartBitOffsetsPtr[blocki];
  //half4 outColor  = half4(0.0h, ((bOff >> 8) & 0xFF)/255.0h, (bOff & 0xFF)/255.0h, 1.0h);
  
  wTexture.write(outColor, gid);
}

// Given coordinates, calculate relative coordinates in a 2d grid
// by applying a block offset. A blockOffset for a 2x2 block
// would be:
//
// [0 1]
// [2 3]

ushort2 relative_coords(const ushort2 rootCoords, const ushort blockDim, ushort blockOffset);

ushort2 relative_coords(const ushort2 rootCoords, const ushort blockDim, ushort blockOffset)
{
  const ushort dx = blockOffset % blockDim;
  const ushort dy = blockOffset / blockDim;
  return rootCoords + ushort2(dx, dy);
}

// A reorder shader operates on a texture that has a fixed width and the blocks
// appear from top to bottom.

// The reorder shader operates on the output of the huffman kernel. Each block group
// is processed such that the Nth pixel in each block is copied to the position in
// each the Nth block. Each block is a complete N*N block so no bounds checking is
// needed in the kernel.

//  b0
//  [0   4]
//  [8  12]

//  b1
//  [1   5]
//  [9  13]

//  b2
//  [2   6]
//  [3   7]

//  b3
//  [10  14]
//  [11  15]

// Reorder as:

// blocki = (0, 1, 2, ...) (based on height of Y)

// 0  at (0,0) write to (0 * nBlocks) + (0,0) -> (0,0)
// 4  at (1,0) write to (0 * nBlocks) + (2,0) -> (2,0)
// 8  at (0,1) write to (0 * nBlocks) + (0,2) -> (0,2)
// 12 at (1,1) write to (0 * nBlocks) + (2,2) -> (2,2)

// After 1 render round

// 0 _ 4  _
// _ _ _  _
// 8 _ 12 _
// _ _ _  _

// After 2 render round2

// 0 1 4  5
// _ _ _  _
// 8 9 12 13
// _ _ _  _

// Final

//  0  1  4  5
//  2  3  6  7
//  8  9 12 13
// 10 11 14 15

kernel void
reorderComputeKernelCoords(texture2d<half, access::read>  rTexture  [[texture(0)]],
                           texture2d<half, access::write> wTexture  [[texture(1)]],
                           constant RenderStepConst & renderStepStruct [[ buffer(0) ]],
                           // FIXME: Change gid to ushort2 type
                           uint2 gid [[thread_position_in_grid]])
{
  const ushort blockDim = 2;
  
  ushort2 blockCoords = ushort2(gid) / blockDim;
  // The (X,Y) coordinate of the block root for current pixel
  ushort2 blockRootCoords = (blockCoords * blockDim);
  // The blocki offset for current pixel
  uint blockiRoot = (uint(blockRootCoords.y) * blockDim) + blockRootCoords.x;
  
  ushort xOffsetFromBlockStart = gid.x - blockRootCoords.x;
  ushort yOffsetFromBlockStart = gid.y - blockRootCoords.y;
  uint offsetFromBlockStart = (uint(yOffsetFromBlockStart) * blockDim) + xOffsetFromBlockStart;

  // Map a block to offset, a 2x2 would be (0, 1, 2, 3)
  uint blocki = blockiRoot + offsetFromBlockStart;
  
  // To fit coords into output width, need to pass in a constant
  // block width since this shader does not have a texture with that info.
  
  const ushort numBlocksFitWidth = renderStepStruct.outWidthInBlocks;
  
  ushort2 blockiFitCoords = ushort2(blocki % numBlocksFitWidth, blocki / numBlocksFitWidth);
  
  // blockiFitCoords now fits the blocki into a fixed width, but need to multiply
  // by blockDim again to get back to original coord system instead of block (X,Y)
  
  ushort2 outCoords = blockiFitCoords * blockDim;
  
  // Add renderStepStruct.renderStep which corresponds to the (dx,dy) in pixels.
  
  outCoords += ushort2(renderStepStruct.renderStep % blockDim, renderStepStruct.renderStep / blockDim);
  
  half4 outColor  = half4(0.0h, outCoords.x/255.0h, outCoords.y/255.0h, 1.0h);
  
  wTexture.write(outColor, gid);
}

kernel void
reorderComputeKernel(texture2d<half, access::read>  rTexture  [[texture(0)]],
                     texture2d<half, access::write> wTexture  [[texture(1)]],
                     constant RenderStepConst & renderStepStruct [[ buffer(0) ]],
                     // FIXME: Change gid to ushort2 type
                     uint2 gid [[thread_position_in_grid]])
{  
  const ushort blockDim = 2;
  
  ushort2 blockCoords = ushort2(gid) / blockDim;
  // The (X,Y) coordinate of the block root for current pixel
  ushort2 blockRootCoords = (blockCoords * blockDim);
  // The blocki offset for current pixel
  uint blockiRoot = (uint(blockRootCoords.y) * blockDim) + blockRootCoords.x;
  
  ushort xOffsetFromBlockStart = gid.x - blockRootCoords.x;
  ushort yOffsetFromBlockStart = gid.y - blockRootCoords.y;
  uint offsetFromBlockStart = (uint(yOffsetFromBlockStart) * blockDim) + xOffsetFromBlockStart;
  
  // Map a block to offset, a 2x2 would be (0, 1, 2, 3)
  uint blocki = blockiRoot + offsetFromBlockStart;
  
  // To fit coords into output width, need to pass in a constant
  // block width since this shader does not have a texture with that info.
  
  const ushort numBlocksFitWidth = renderStepStruct.outWidthInBlocks;
  
  ushort2 blockiFitCoords = ushort2(blocki % numBlocksFitWidth, blocki / numBlocksFitWidth);
  
  // blockiFitCoords now fits the blocki into a fixed width, but need to multiply
  // by blockDim again to get back to original coord system instead of block (X,Y)
  
  ushort2 outCoords = blockiFitCoords * blockDim;
  
  // Add renderStepStruct.renderStep which corresponds to the (dx,dy) in pixels.
  
  outCoords += ushort2(renderStepStruct.renderStep % blockDim, renderStepStruct.renderStep / blockDim);
  
  //half4 outColor  = half4(0.0h, outCoords.x/255.0h, outCoords.y/255.0h, 1.0h);
  //wTexture.write(outColor, gid);
  
  half4 inColor  = rTexture.read(gid);
  wTexture.write(inColor, outCoords);
}
