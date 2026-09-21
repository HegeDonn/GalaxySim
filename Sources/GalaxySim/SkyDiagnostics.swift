import Foundation
import Metal
import simd

func runSkyDiagnostics(host: SimHost, output: String) throws {
    let ctx=host.ctx
    let pipeline=try ctx.computePipeline("skyInverseCheck")
    let buffer=ctx.device.makeBuffer(length: 15*16,options: .storageModeShared)!
    let cb=ctx.queue.makeCommandBuffer()!, enc=cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline); enc.setBuffer(buffer,offset:0,index:0)
    enc.dispatchThreads(MTLSize(width:15,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:15,height:1,depth:1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    if let error=cb.error { throw error }
    let values=buffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:15)
    for i in 0..<15 {
        let v=values[i]
        precondition(v.x.isFinite && v.x<0.0002 && v.y<0.002,"Sky inverse round trip failed")
        precondition(v.z>=1 && v.w<=1,"Forward blue / aft red Doppler failed")
    }
    print("PASS: GPU background inverse aberration and Doppler, 15 cases through beta 0.996")
    let flight=FlightCamera(), chase=ChaseCamera()
    flight.position = .zero; flight.travelDirection=SIMD3(0,0,-1)
    let texture=host.makeCaptureTexture(1440,900)!
    for (name,beta,yaw) in [("rest",Float(0),Float(0)),("forward",0.95,0),("side",0.95,1.57),("aft",0.95,3.14),("extreme",0.995,0)] {
        flight.beta=beta; chase.pose(yaw:yaw,elevation:0)
        let command=ctx.queue.makeCommandBuffer()!
        host.renderer.render(into:texture,commandBuffer:command,simulation:host.sim,camera:host.camera,
            viewOverride:chase.galaxyView(aspect:1.6,flight:flight),relativity:flight.uniforms(),backgroundOnly:true)
        command.commit(); command.waitUntilCompleted()
        if let error=command.error { throw error }
        let saved = try host.saveTexture(texture,to:output+"/sky-"+name+".png")
        precondition(saved)
    }
    print("PASS: background-only rest / forward / side / aft / extreme renders (no simulated galaxies or ship)")
}
