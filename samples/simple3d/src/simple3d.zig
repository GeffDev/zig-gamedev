const builtin = @import("builtin");
const std = @import("std");
const w = @import("win32");
const gr = @import("graphics");
usingnamespace @import("vectormath");
const vhr = gr.vhr;

pub export var D3D12SDKVersion: u32 = 4;
pub export var D3D12SDKPath: [*:0]const u8 = ".\\d3d12\\";

const FrameStats = struct {
    time: f64,
    delta_time: f32,
    fps: f32,
    average_cpu_time: f32,
    timer: std.time.Timer,
    previous_time_ns: u64,
    fps_refresh_time_ns: u64,
    frame_counter: u64,

    fn init() FrameStats {
        return .{
            .time = 0.0,
            .delta_time = 0.0,
            .fps = 0.0,
            .average_cpu_time = 0.0,
            .timer = std.time.Timer.start() catch unreachable,
            .previous_time_ns = 0,
            .fps_refresh_time_ns = 0,
            .frame_counter = 0,
        };
    }

    fn update(self: *FrameStats) void {
        const now_ns = self.timer.read();
        self.time = @intToFloat(f64, now_ns) / std.time.ns_per_s;
        self.delta_time = @intToFloat(f32, now_ns - self.previous_time_ns) / std.time.ns_per_s;
        self.previous_time_ns = now_ns;

        if ((now_ns - self.fps_refresh_time_ns) >= std.time.ns_per_s) {
            const t = @intToFloat(f64, now_ns - self.fps_refresh_time_ns) / std.time.ns_per_s;
            const fps = @intToFloat(f64, self.frame_counter) / t;
            const ms = (1.0 / fps) * 1000.0;

            self.fps = @floatCast(f32, fps);
            self.average_cpu_time = @floatCast(f32, ms);
            self.fps_refresh_time_ns = now_ns;
            self.frame_counter = 0;
        }
        self.frame_counter += 1;
    }
};

fn processWindowMessage(
    window: w.HWND,
    message: w.UINT,
    wparam: w.WPARAM,
    lparam: w.LPARAM,
) callconv(w.WINAPI) w.LRESULT {
    const processed = switch (message) {
        w.user32.WM_DESTROY => blk: {
            w.user32.PostQuitMessage(0);
            break :blk true;
        },
        w.user32.WM_KEYDOWN => blk: {
            if (wparam == w.VK_ESCAPE) {
                w.user32.PostQuitMessage(0);
                break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
    return if (processed) 0 else w.user32.DefWindowProcA(window, message, wparam, lparam);
}

fn initWindow(name: [*:0]const u8, width: u32, height: u32) !w.HWND {
    const winclass = w.user32.WNDCLASSEXA{
        .style = 0,
        .lpfnWndProc = processWindowMessage,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = @ptrCast(w.HINSTANCE, w.kernel32.GetModuleHandleW(null)),
        .hIcon = null,
        .hCursor = w.LoadCursorA(null, @intToPtr(w.LPCSTR, 32512)),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = name,
        .hIconSm = null,
    };
    _ = try w.user32.registerClassExA(&winclass);

    const style = w.user32.WS_OVERLAPPED +
        w.user32.WS_SYSMENU +
        w.user32.WS_CAPTION +
        w.user32.WS_MINIMIZEBOX;

    var rect = w.RECT{ .left = 0, .top = 0, .right = @intCast(i32, width), .bottom = @intCast(i32, height) };
    try w.user32.adjustWindowRectEx(&rect, style, false, 0);

    return try w.user32.createWindowExA(
        0,
        name,
        name,
        style + w.WS_VISIBLE,
        -1,
        -1,
        rect.right - rect.left,
        rect.bottom - rect.top,
        null,
        null,
        winclass.hInstance,
        null,
    );
}

pub fn main() !void {
    const window_name = "zig-gamedev: simple3d";
    const window_width = 800;
    const window_height = 800;

    _ = w.SetProcessDPIAware();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        std.debug.assert(leaked == false);
    }
    const allocator = &gpa.allocator;

    const window = try initWindow(window_name, window_width, window_height);
    var grctx = try gr.GraphicsContext.init(window);
    defer grctx.deinit(&gpa.allocator);

    const pipeline = blk: {
        const input_layout_desc = [_]w.D3D12_INPUT_ELEMENT_DESC{
            w.D3D12_INPUT_ELEMENT_DESC.init("POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0),
        };
        var pso_desc = w.D3D12_GRAPHICS_PIPELINE_STATE_DESC{
            .pRootSignature = null,
            .VS = w.D3D12_SHADER_BYTECODE.initZero(),
            .PS = w.D3D12_SHADER_BYTECODE.initZero(),
            .DS = w.D3D12_SHADER_BYTECODE.initZero(),
            .HS = w.D3D12_SHADER_BYTECODE.initZero(),
            .GS = w.D3D12_SHADER_BYTECODE.initZero(),
            .StreamOutput = w.D3D12_STREAM_OUTPUT_DESC.initZero(),
            .BlendState = w.D3D12_BLEND_DESC.initDefault(),
            .SampleMask = 0xffff_ffff,
            .RasterizerState = w.D3D12_RASTERIZER_DESC.initDefault(),
            .DepthStencilState = blk1: {
                var desc = w.D3D12_DEPTH_STENCIL_DESC.initDefault();
                desc.DepthEnable = w.FALSE;
                break :blk1 desc;
            },
            .InputLayout = .{
                .pInputElementDescs = &input_layout_desc,
                .NumElements = input_layout_desc.len,
            },
            .IBStripCutValue = .DISABLED,
            .PrimitiveTopologyType = .TRIANGLE,
            .NumRenderTargets = 1,
            .RTVFormats = [_]w.DXGI_FORMAT{.R8G8B8A8_UNORM} ++ [_]w.DXGI_FORMAT{.UNKNOWN} ** 7,
            .DSVFormat = .UNKNOWN,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .NodeMask = 0,
            .CachedPSO = w.D3D12_CACHED_PIPELINE_STATE.initZero(),
            .Flags = .{},
        };
        break :blk try grctx.createGraphicsShaderPipeline(
            allocator,
            &pso_desc,
            "content/shaders/simple3d.vs.cso",
            "content/shaders/simple3d.ps.cso",
        );
    };
    defer {
        _ = grctx.releasePipeline(pipeline);
    }

    const vertex_buffer = try grctx.createCommittedResource(
        .DEFAULT,
        .{},
        &w.D3D12_RESOURCE_DESC.initBuffer(3 * @sizeOf(Vec3)),
        .{ .COPY_DEST = true },
        null,
    );
    //const vertex_buffer_srv = grctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
    //grctx.device.CreateShaderResourceView(
    //   grctx.getResource(vertex_buffer),
    //  &w.D3D12_SHADER_RESOURCE_VIEW_DESC.initTypedBuffer(.R32G32B32_FLOAT, 0, 3),
    // vertex_buffer_srv,
    //);
    defer _ = grctx.releaseResource(vertex_buffer);

    const index_buffer = try grctx.createCommittedResource(
        .DEFAULT,
        .{},
        &w.D3D12_RESOURCE_DESC.initBuffer(3 * @sizeOf(u32)),
        .{ .COPY_DEST = true },
        null,
    );
    //const index_buffer_srv = grctx.allocateCpuDescriptors(.CBV_SRV_UAV, 1);
    //grctx.device.CreateShaderResourceView(
    //   grctx.getResource(index_buffer),
    //  &w.D3D12_SHADER_RESOURCE_VIEW_DESC.initTypedBuffer(.R32G32B32_FLOAT, 0, 3),
    // vertex_buffer_srv,
    //);
    defer _ = grctx.releaseResource(index_buffer);

    try grctx.beginFrame();

    const upload_verts = grctx.allocateUploadBufferRegion(Vec3, 3);
    upload_verts.cpu_slice[0] = vec3Init(-0.7, -0.7, 0.0);
    upload_verts.cpu_slice[1] = vec3Init(0.0, 0.7, 0.0);
    upload_verts.cpu_slice[2] = vec3Init(0.7, -0.7, 0.0);

    grctx.cmdlist.CopyBufferRegion(
        grctx.getResource(vertex_buffer),
        0,
        upload_verts.buffer,
        upload_verts.buffer_offset,
        upload_verts.cpu_slice.len * @sizeOf(Vec3),
    );

    const upload_indices = grctx.allocateUploadBufferRegion(u32, 3);
    upload_indices.cpu_slice[0] = 0;
    upload_indices.cpu_slice[1] = 1;
    upload_indices.cpu_slice[2] = 2;

    grctx.cmdlist.CopyBufferRegion(
        grctx.getResource(index_buffer),
        0,
        upload_indices.buffer,
        upload_indices.buffer_offset,
        upload_indices.cpu_slice.len * @sizeOf(u32),
    );

    grctx.addTransitionBarrier(vertex_buffer, .{ .VERTEX_AND_CONSTANT_BUFFER = true });
    grctx.addTransitionBarrier(index_buffer, .{ .INDEX_BUFFER = true });
    grctx.flushResourceBarriers();

    try grctx.flushGpuCommands();
    try grctx.finishGpuCommands();

    var stats = FrameStats.init();

    while (true) {
        var message = std.mem.zeroes(w.user32.MSG);
        if (w.user32.PeekMessageA(&message, null, 0, 0, w.user32.PM_REMOVE) > 0) {
            _ = w.user32.DispatchMessageA(&message);
            if (message.message == w.user32.WM_QUIT)
                break;
        } else {
            stats.update();
            {
                var buffer = [_]u8{0} ** 64;
                const text = std.fmt.bufPrint(
                    buffer[0..],
                    "FPS: {d:.1}  CPU time: {d:.3} ms | {s}",
                    .{ stats.fps, stats.average_cpu_time, window_name },
                ) catch unreachable;
                _ = w.SetWindowTextA(window, @ptrCast([*:0]const u8, text.ptr));
            }

            try grctx.beginFrame();

            const back_buffer = grctx.getBackBuffer();

            grctx.addTransitionBarrier(back_buffer.resource_handle, .{ .RENDER_TARGET = true });
            grctx.flushResourceBarriers();

            grctx.cmdlist.OMSetRenderTargets(
                1,
                &[_]w.D3D12_CPU_DESCRIPTOR_HANDLE{back_buffer.descriptor_handle},
                w.TRUE,
                null,
            );
            grctx.cmdlist.ClearRenderTargetView(
                back_buffer.descriptor_handle,
                &[4]f32{ 0.2, 0.4, 0.8, 1.0 },
                0,
                null,
            );
            grctx.setCurrentPipeline(pipeline);
            grctx.cmdlist.IASetPrimitiveTopology(.TRIANGLELIST);
            grctx.cmdlist.IASetVertexBuffers(0, 1, &[_]w.D3D12_VERTEX_BUFFER_VIEW{.{
                .BufferLocation = grctx.getResource(vertex_buffer).GetGPUVirtualAddress(),
                .SizeInBytes = 3 * @sizeOf(Vec3),
                .StrideInBytes = @sizeOf(Vec3),
            }});
            grctx.cmdlist.IASetIndexBuffer(&.{
                .BufferLocation = grctx.getResource(index_buffer).GetGPUVirtualAddress(),
                .SizeInBytes = 3 * @sizeOf(u32),
                .Format = .R32_UINT,
            });
            grctx.cmdlist.DrawIndexedInstanced(3, 1, 0, 0, 0);

            grctx.addTransitionBarrier(back_buffer.resource_handle, w.D3D12_RESOURCE_STATE_PRESENT);
            grctx.flushResourceBarriers();

            try grctx.endFrame();
        }
    }

    try grctx.finishGpuCommands();
}
