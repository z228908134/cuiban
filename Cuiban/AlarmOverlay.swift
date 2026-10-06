import SwiftUI

struct AlarmOverlay: View {
    @EnvironmentObject var store: TaskStore
    @EnvironmentObject var alarm: AlarmCenter

    let task: TaskItem

    @State private var now = Date()
    @State private var muted = false
    @State private var pulsing = false
    @State private var previewOpen = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var overdueSeconds: TimeInterval {
        max(0, now.timeIntervalSince(task.effectiveDue))
    }

    var body: some View {
        ZStack {
            alarmRed
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 10)

                bellIcon

                Text("该做了！")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.top, 14)

                Text(task.title.isEmpty ? "（未命名任务）" : task.title)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 8)

                Text("已逾期 \(human(overdueSeconds)) · 第 \(max(1, task.nagCount)) 次催你")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.top, 12)

                if !task.photos.isEmpty {
                    PhotoStrip(names: task.photos, size: 76, maxCount: 3, radius: 12)
                        .padding(.top, 14)
                        .onTapGesture { previewOpen = true }
                }

                if !task.note.isEmpty {
                    Text(task.note)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.top, 10)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                }

                Spacer(minLength: 16)

                Button {
                    store.complete(id: task.id)
                } label: {
                    Text("完成了")
                        .font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                        .foregroundColor(alarmRed)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    snoozeBtn(5, "延后 5 分")
                    snoozeBtn(10, "延后 10 分")
                    snoozeBtn(30, "延后 30 分")
                }
                .padding(.top, 12)

                Button {
                    store.markNagged(id: task.id)
                    alarm.dismiss(id: task.id)
                } label: {
                    Text("先关掉，\(task.resolvedInterval(store.settings.defaultIntervalMinutes)) 分钟后再催")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.top, 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onReceive(timer) { now = $0 }
        .fullScreenCover(isPresented: $previewOpen) {
            PhotoViewer(
                images: AttachmentStore.loadAll(task.photos),
                titles: task.photos.indices.map { "第 \($0 + 1) 张，共 \(task.photos.count) 张" }
            )
        }
        .onAppear {
            pulsing = true
            if store.settings.soundEnabled && !muted {
                AlarmSound.shared.start()
            }
        }
        .onChange(of: task.isDone) { done in
            if done { alarm.dismiss(id: task.id) }
        }
    }

    private var bellIcon: some View {
        Image(systemName: "bell.and.waves.left.and.right.fill")
            .font(.system(size: 52))
            .foregroundColor(.white)
            .scaleEffect(pulsing ? 1.12 : 0.92)
            .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: pulsing)
            .onTapGesture {
                muted.toggle()
                if muted {
                    AlarmSound.shared.stop()
                } else if store.settings.soundEnabled {
                    AlarmSound.shared.start()
                }
            }
    }

    private func snoozeBtn(_ m: Int, _ label: String) -> some View {
        Button {
            store.snooze(id: task.id, minutes: m)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.white.opacity(0.18))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
