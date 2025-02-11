//
//  ContentView.swift
//  H265Encoder
//
//  Created by kohshin1977 on 2025/02/11.
//
import SwiftUI
import AVFoundation
import VideoToolbox

// NALUヘッダ（ファイル書き出し用）
fileprivate var NALUHeader: [UInt8] = [0, 0, 0, 1]

// H.265 を使用するかどうか（false にすれば H.264 になります）
let H265 = true

// MARK: - VideoToolbox 圧縮出力コールバック

/// VideoToolbox の圧縮出力コールバック関数
/// - Parameters:
///   - outputCallbackRefCon: コールバック時に渡すユーザーポインタ（ここでは CameraManager へのポインタ）
///   - sourceFrameRefCon: ソースフレームの参照（今回は使用しない）
///   - status: エラーコード
///   - infoFlags: 情報フラグ
///   - sampleBuffer: 圧縮後のサンプルバッファ
func compressionOutputCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
                               sourceFrameRefCon: UnsafeMutableRawPointer?,
                               status: OSStatus,
                               infoFlags: VTEncodeInfoFlags,
                               sampleBuffer: CMSampleBuffer?) -> Void {
    // エラーチェック
    guard status == noErr else {
        print("エラー: \(status)")
        return
    }
    
    if infoFlags == .frameDropped {
        print("フレームがドロップされました")
        return
    }
    
    guard let sampleBuffer = sampleBuffer else {
        print("sampleBufferがnilです")
        return
    }
    
    if !CMSampleBufferDataIsReady(sampleBuffer) {
        print("sampleBufferのデータが準備できていません")
        return
    }
    
    // CameraManager オブジェクトを取得
    let manager: CameraManager = Unmanaged.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
    
    // サンプルアタッチメントの取得（SPS, PPS, VPS などのパラメータ情報）
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
        print("attachments: \(attachments)")
        let rawDic: UnsafeRawPointer = CFArrayGetValueAtIndex(attachments, 0)
        let dic: CFDictionary = Unmanaged.fromOpaque(rawDic).takeUnretainedValue()
        
        // キーフレームかどうかの判定
        let keyFrame = !CFDictionaryContainsKey(dic, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        if keyFrame {
            print("IDRフレーム")
            
            // フォーマット記述子から SPS/PPS(VPS) を取得
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
            var spsSize: Int = 0
            var spsCount: Int = 0
            var nalHeaderLength: Int32 = 0
            var sps: UnsafePointer<UInt8>?
            var status: OSStatus
            
            if H265 {
                // HEVC（H.265）の場合 VPS, SPS, PPS の3種類を取得
                var vpsSize: Int = 0
                var vpsCount: Int = 0
                var vps: UnsafePointer<UInt8>?
                var ppsSize: Int = 0
                var ppsCount: Int = 0
                var pps: UnsafePointer<UInt8>?
                
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format!, parameterSetIndex: 0, parameterSetPointerOut: &vps, parameterSetSizeOut: &vpsSize, parameterSetCountOut: &vpsCount, nalUnitHeaderLengthOut: &nalHeaderLength)
                if status == noErr {
                    print("HEVC VPS: \(String(describing: vps)), サイズ: \(vpsSize)")
                    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format!, parameterSetIndex: 1, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nalHeaderLength)
                    if status == noErr {
                        print("HEVC SPS: \(String(describing: sps)), サイズ: \(spsSize)")
                        status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format!, parameterSetIndex: 2, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: &nalHeaderLength)
                        if status == noErr {
                            print("HEVC PPS: \(String(describing: pps)), サイズ: \(ppsSize)")
                            
                            let vpsData = NSData(bytes: vps, length: vpsSize)
                            let spsData = NSData(bytes: sps, length: spsSize)
                            let ppsData = NSData(bytes: pps, length: ppsSize)
                            
                            manager.handle(sps: spsData, pps: ppsData, vps: vpsData)
                        }
                    }
                }
            } else {
                // H.264 の場合は SPS と PPS のみ
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                                      parameterSetIndex: 0,
                                                                      parameterSetPointerOut: &sps,
                                                                      parameterSetSizeOut: &spsSize,
                                                                      parameterSetCountOut: &spsCount,
                                                                      nalUnitHeaderLengthOut: &nalHeaderLength) == noErr {
                    print("SPS: \(String(describing: sps)), サイズ: \(spsSize)")
                    
                    var ppsSize: Int = 0
                    var ppsCount: Int = 0
                    var pps: UnsafePointer<UInt8>?
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                                          parameterSetIndex: 1,
                                                                          parameterSetPointerOut: &pps,
                                                                          parameterSetSizeOut: &ppsSize,
                                                                          parameterSetCountOut: &ppsCount,
                                                                          nalUnitHeaderLengthOut: &nalHeaderLength) == noErr {
                        print("PPS: \(String(describing: pps)), サイズ: \(ppsSize)")
                        
                        let spsData = NSData(bytes: sps, length: spsSize)
                        let ppsData = NSData(bytes: pps, length: ppsSize)
                        
                        manager.handle(sps: spsData, pps: ppsData)
                    }
                }
            }
        } // キーフレーム処理終了
        
        // フレームデータの取得と書き出し
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr {
            var bufferOffset: Int = 0
            let AVCCHeaderLength = 4
            
            while bufferOffset < (totalLength - AVCCHeaderLength) {
                var NALUnitLength: UInt32 = 0
                // 最初の4バイトが NALUnit の長さ
                memcpy(&NALUnitLength, dataPointer?.advanced(by: bufferOffset), AVCCHeaderLength)
                NALUnitLength = CFSwapInt32BigToHost(NALUnitLength)
                
                let data = NSData(bytes: dataPointer?.advanced(by: bufferOffset + AVCCHeaderLength), length: Int(NALUnitLength))
                manager.encode(data: data, isKeyFrame: keyFrame)
                
                // 次の NAL Unit へ移動
                bufferOffset += AVCCHeaderLength
                bufferOffset += Int(NALUnitLength)
            }
        }
    }
}

// MARK: - CameraManager クラス

/// AVCaptureSession の管理、圧縮処理、ファイル書き出しを行うクラス
class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// キャプチャセッション
    var captureSession = AVCaptureSession()
    /// キャプチャ用のディスパッチキュー
    let captureQueue = DispatchQueue(label: "videotoolbox.compression.capture")
    /// 圧縮処理用のディスパッチキュー
    let compressionQueue = DispatchQueue(label: "videotoolbox.compression.compression")
    /// VideoToolbox の圧縮セッション
    var compressionSession: VTCompressionSession?
    /// 書き出し用ファイルハンドラ
    var fileHandler: FileHandle?
    /// キャプチャ中かどうか
    @Published var isCapturing: Bool = false
    /// カメラプレビュー表示用のレイヤー
    var previewLayer: AVCaptureVideoPreviewLayer!
    
    override init() {
        super.init()
        // 一時ファイルのパス設定（H.265 / H.264 に応じてファイル名を変更）
        let path = NSTemporaryDirectory() + (H265 ? "temp.h265" : "temp.h264")
        // 既存ファイルの削除
        try? FileManager.default.removeItem(atPath: path)
        // 新規ファイルの作成
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        fileHandler = FileHandle(forWritingAtPath: path)
        
        // キャプチャセッションのセットアップ
        setupCaptureSession()
    }
    
    /// キャプチャセッションのセットアップ
    func setupCaptureSession() {
        // 高解像度に設定
        captureSession.sessionPreset = .high
        
        // カメラデバイスの取得
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("カメラデバイスが取得できません")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
        } catch {
            print("カメラ入力の追加に失敗しました: \(error)")
        }
        
        // キャプチャ出力の設定
        let output = AVCaptureVideoDataOutput()
        // YUV 420BiPlanar 形式
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }
        
        // 出力接続の向き設定（ここでは Portrait 固定）
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        // プレビュー表示用レイヤーの作成
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        
        // キャプチャ開始
        captureSession.startRunning()
    }
    
    /// キャプチャを開始する
    func startCapture() {
        isCapturing = true
        print("キャプチャ開始")
    }
    
    /// キャプチャを停止する
    func stopCapture() {
        isCapturing = false
        print("キャプチャ停止")
        guard let compressionSession = compressionSession else {
            return
        }
        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: CMTime.invalid)
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        // 圧縮セッションが未作成の場合、初回に作成する
        if compressionSession == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("解像度: \(width) x \(height)")
            
            let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                    width: Int32(width),
                                                    height: Int32(height),
                                                    codecType: H265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                    encoderSpecification: nil,
                                                    imageBufferAttributes: nil,
                                                    compressedDataAllocator: nil,
                                                    outputCallback: compressionOutputCallback,
                                                    refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                                    compressionSessionOut: &compressionSession)
            guard let session = compressionSession else {
                print("圧縮セッションの作成に失敗しました: \(status)")
                return
            }
            
            // プロファイルレベルの設定
            if H265 {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: kVTProfileLevel_HEVC_Main_AutoLevel)
            } else {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: kVTProfileLevel_H264_Main_AutoLevel)
            }
            // リアルタイムエンコードの設定
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: true as CFTypeRef)
            // キーフレーム間隔の設定
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 10 as CFTypeRef)
            // ビットレートなどの設定
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: width * height * 2 * 32 as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [width * height * 2 * 4, 1] as CFArray)
            
            VTCompressionSessionPrepareToEncodeFrames(session)
        }
        
        guard let session = compressionSession else {
            return
        }
        
        // キャプチャ中でなければ処理しない
        guard isCapturing else {
            return
        }
        
        // 圧縮処理（ディスパッチキュー内で同期的に実行）
        compressionQueue.sync {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            
            let presentationTimeStamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetOutputDuration(sampleBuffer)
            
            VTCompressionSessionEncodeFrame(session,
                                            imageBuffer: pixelBuffer,
                                            presentationTimeStamp: presentationTimeStamp,
                                            duration: duration,
                                            frameProperties: nil,
                                            sourceFrameRefcon: nil,
                                            infoFlagsOut: nil)
        }
    }
    
    // MARK: - ファイル書き出し
    
    /// SPS, PPS, (VPS) のデータをファイルに書き出す
    /// - Parameters:
    ///   - sps: SPS データ
    ///   - pps: PPS データ
    ///   - vps: VPS データ（HEVC のみ）
    func handle(sps: NSData, pps: NSData, vps: NSData? = nil) {
        guard let fh = fileHandler else {
            return
        }
        
        let headerData = NSData(bytes: NALUHeader, length: NALUHeader.count)
        if let vpsData = vps {
            print("VPSデータ取得: \(vpsData.length) バイト")
            fh.write(headerData as Data)
            fh.write(vpsData as Data)
        }
        fh.write(headerData as Data)
        fh.write(sps as Data)
        fh.write(headerData as Data)
        fh.write(pps as Data)
    }
    
    /// フレームデータをファイルに書き出す
    /// - Parameters:
    ///   - data: フレームデータ
    ///   - isKeyFrame: キーフレームかどうか
    func encode(data: NSData, isKeyFrame: Bool) {
        guard let fh = fileHandler else {
            return
        }
        let headerData = NSData(bytes: NALUHeader, length: NALUHeader.count)
        fh.write(headerData as Data)
        fh.write(data as Data)
    }
}

// MARK: - SwiftUI 用プレビュー表示ビュー

/// UIViewRepresentable を使って AVCaptureVideoPreviewLayer を表示するためのビュー
struct CameraPreviewView: UIViewRepresentable {
    /// カメラ管理クラスのインスタンス
    @ObservedObject var manager: CameraManager
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        // プレビュー用レイヤーのフレームを設定してビューに追加
        manager.previewLayer.frame = UIScreen.main.bounds
        view.layer.addSublayer(manager.previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // 画面サイズ変更時にプレビューのフレームを更新
        manager.previewLayer.frame = uiView.bounds
    }
}

struct ContentView: View {
    // カメラ管理クラスを StateObject として保持
    @StateObject var cameraManager = CameraManager()
    
    var body: some View {
        ZStack {
            // カメラプレビューの表示
            CameraPreviewView(manager: cameraManager)
                .edgesIgnoringSafeArea(.all)
            
            // キャプチャ開始／停止ボタン（下部中央に配置）
            VStack {
                Spacer()
                Button(action: {
                    if cameraManager.isCapturing {
                        cameraManager.stopCapture()
                    } else {
                        cameraManager.startCapture()
                    }
                }) {
                    Text(cameraManager.isCapturing ? "停止" : "開始")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(8)
                }
                .padding(.bottom, 40)
            }
        }
    }
}

#Preview {
    ContentView()
}
