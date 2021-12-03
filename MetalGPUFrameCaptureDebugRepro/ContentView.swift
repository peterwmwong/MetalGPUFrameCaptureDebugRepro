//
//  ContentView.swift
//  MetalGPUFrameCaptureDebugRepro
//
//  Created by Peter Wong on 12/2/21.
//

import SwiftUI
import MetalKit

typealias VertexPosition = SIMD4<Float>
typealias VertexFnBuffer = (VertexPosition, VertexPosition, VertexPosition)

let TRIANGLE_VERTICES: VertexFnBuffer = (
    VertexPosition( 1, -1,  0, 1),
    VertexPosition(-1, -1,  0, 1),
    VertexPosition( 0,  1,  0, 1)
)

let COLOR_PIXEL_FORMAT = MTLPixelFormat.bgra8Unorm_srgb

func createPipelineState(device: MTLDevice, vertexFn: MTLFunction, fragFn: MTLFunction) -> MTLRenderPipelineState {
    let desc = MTLRenderPipelineDescriptor()
    desc.label = "RenderPipeline"
    desc.vertexFunction = vertexFn
    desc.fragmentFunction = fragFn
    desc.colorAttachments[0].pixelFormat = COLOR_PIXEL_FORMAT
    desc.supportIndirectCommandBuffers = true
    desc.inputPrimitiveTopology = .triangle
    
    let vertexDesc = MTLVertexDescriptor()
    vertexDesc.attributes[0].bufferIndex = 0
    vertexDesc.attributes[0].offset = 0
    vertexDesc.attributes[0].format = .float4
    vertexDesc.layouts[0].stride = MemoryLayout<VertexPosition>.stride
    vertexDesc.layouts[0].stepRate = 1
    vertexDesc.layouts[0].stepFunction = .perVertex
    desc.vertexDescriptor = vertexDesc
    
    return try! device.makeRenderPipelineState(descriptor: desc)
}

func createVertexFnBuffer(device: MTLDevice) -> MTLBuffer {
    let buf = device.makeBuffer(length: MemoryLayout<VertexFnBuffer>.size, options: [.storageModeShared])!
    buf.label = "Vertex Fn Input Buffer"
    buf
        .contents()
        .bindMemory(
            to: VertexFnBuffer.self,
            capacity: MemoryLayout<VertexFnBuffer>.size
        )
        .pointee = TRIANGLE_VERTICES
    return buf
}

func createIndirectCommandBuffer(device: MTLDevice, pipelineState: MTLRenderPipelineState, vertexFnArgBuffer: MTLBuffer) -> MTLIndirectCommandBuffer {
    let desc = MTLIndirectCommandBufferDescriptor()
    desc.commandTypes = .draw
    desc.inheritBuffers = false
    desc.inheritPipelineState = false
    desc.maxVertexBufferBindCount = 1
    desc.maxFragmentBufferBindCount = 0

    let buf = device.makeIndirectCommandBuffer(descriptor: desc, maxCommandCount: 1, options: MTLResourceOptions.storageModeManaged)!
    buf.label = "IndirectCommandBuffer"
    
    let renderEncoder = buf.indirectRenderCommandAt(0)
    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBuffer(vertexFnArgBuffer, offset: 0, at: 0)
    renderEncoder.drawPrimitives(.triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 0)
    
    return buf
}

struct ContentView: NSViewRepresentable {
    class Coordinator : NSObject, MTKViewDelegate {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let pipelineState: MTLRenderPipelineState
        let indirectCommandBuffer: MTLIndirectCommandBuffer
        let vertexFnArgBuffer: MTLBuffer
        var drawableViewport = MTLViewport(originX: 0, originY: 0, width: 1, height: 1, znear: 0, zfar: 1)
        
        override init() {
            device = MTLCreateSystemDefaultDevice()!
            commandQueue = device.makeCommandQueue()!

            let library = try! device.makeLibrary(
                source: """
                    struct VertexIn {
                        float4 position [[ attribute(0) ]];
                    };

                    struct VertexOut {
                        float4 position [[ position ]];
                        float4 color;
                    };

                    vertex VertexOut vertexShader(VertexIn in [[ stage_in ]]) {
                        VertexOut out;
                        out.position = in.position;
                        out.color = float4(0.0, 1.0, 0.0, 1.0);
                        return out;
                    }

                    fragment float4 fragmentShader(VertexOut in [[ stage_in ]]) {
                        return in.color;
                    }
                """,
                options: nil
            )
            pipelineState = createPipelineState(
                device: device,
                vertexFn: library.makeFunction(name: "vertexShader")!,
                fragFn: library.makeFunction(name: "fragmentShader")!
            )
            vertexFnArgBuffer = createVertexFnBuffer(device: device)
            indirectCommandBuffer = createIndirectCommandBuffer(device: device, pipelineState: pipelineState, vertexFnArgBuffer: vertexFnArgBuffer)
        }
        
        func draw(in view: MTKView) {
            let commandBuffer = commandQueue.makeCommandBuffer()!
            commandBuffer.label = "@CommandBuffer"
            
            let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: view.currentRenderPassDescriptor!)!
            renderEncoder.label = "@RenderCommandEncoder"
            renderEncoder.setViewport(drawableViewport)

            // ===============================================================================
            // Uncomment the following lines (Issue 1, Issue 2) to make shader debugging work.
            // ===============================================================================
            
            // [Issue 1]: Eventhough the indirect command buffer specifies the render pipeline state (and sets inheritPipelineState = false),
            //            without the following, attempting to debug a shader yields errors: "Unable to connect to device (6)" -> <click Cancel> -> "(com.apple.gputools.MTLReplayer error 150.)".
            // renderEncoder.setRenderPipelineState(pipelineState)
            
            // [Issue 2]: Assuming Issue 1's line has been uncommented...
            //            Eventhough the indirect command buffer provides the vertex buffer, without the following, attempting to debug a
            //            shader yields error: "Function argument 'vertexBuffer.0' does not have a valid vertex buffer binding at index '0'".
            // renderEncoder.setVertexBuffer(vertexFnArgBuffer, offset: 0, index: 0)
            
            renderEncoder.use(vertexFnArgBuffer, usage: .read, stages: .vertex)
            renderEncoder.executeCommandsInBuffer(indirectCommandBuffer, range: 0..<1)
            renderEncoder.endEncoding()
            
            commandBuffer.present(view.currentDrawable!)
            commandBuffer.commit()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableViewport = MTLViewport(originX: 0, originY: 0, width: size.width, height: size.height, znear: 0, zfar: 1)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: NSViewRepresentableContext<ContentView>) -> MTKView {
        let view = MTKView()
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = COLOR_PIXEL_FORMAT
        view.delegate = context.coordinator
        view.device = context.coordinator.device
        view.preferredFramesPerSecond = 30
        return view
    }
    
    func updateNSView(_ nsView: MTKView, context: NSViewRepresentableContext<ContentView>) {}
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
