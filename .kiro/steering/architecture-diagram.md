# Architecture Diagram

_Last updated: 2026-10-17_

`structure.md` のアーキテクチャとディレクトリ層を図解した補助ドキュメント。依存方向・層の責務・ディレクトリ構成の唯一の正は `structure.md` であり、本書はその可視化のみを担う。

## 1. 単方向レイヤード（依存方向）

左の層は右の層を知らない。依存は常に `Types` 方向へ流れる。

```mermaid
flowchart LR
    UI["UI<br/><small>SwiftUI 画面</small>"] --> Session["Session<br/><small>状態所有と<br/>オーケストレーション</small>"]
    Session --> Services["Services<br/><small>外部I/Oと端末資源</small>"]
    Services --> Domain["Domain<br/><small>純関数のみ</small>"]
    Domain --> Types["Types<br/><small>共有の値型・列挙</small>"]
    UI -.->|"購読"| Session
    Services -.->|"依存"| Types
    Session -.->|"依存"| Types

    classDef types fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px,color:#1b5e20
    classDef domain fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#0d47a1
    classDef services fill:#fff3e0,stroke:#ef6c00,stroke-width:2px,color:#e65100
    classDef session fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#4a148c
    classDef ui fill:#fce4ec,stroke:#ad1457,stroke-width:2px,color:#880e4f

    class Types types
    class Domain domain
    class Services services
    class Session session
    class UI ui
```

**Why**: 層をまたぐ循環依存を防ぎ、Domain をカメラなしで単体検証可能にし、状態の書き込み点を1つに集約して判定の整合性を保つ。

## 2. 各層の責務と主要型

```mermaid
flowchart TD
    subgraph L5["UI / NekozeFix/UI/"]
        ui1["SessionSnapshot の公開状態だけを購読<br/>判定・状態を持たない"]
    end
    subgraph L4["Session / NekozeFix/Session/"]
        s1["PostureSessionManager<br/>@MainActor・状態の唯一の書き込み点"]
        s2["FrameThrottle"]
        s3["MainHopGate"]
        s4["DimPowerPolicy"]
        s5["SettingsStore"]
    end
    subgraph L3["Services / NekozeFix/Services/"]
        sv1["CameraSessionManager"]
        sv2["PoseDetector"]
        sv3["MotionService"]
        sv4["AlertPlayer"]
        sv5["DeviceRotationService"]
    end
    subgraph L2["Domain / NekozeFix/Domain/"]
        d1["PostureAnalyzer<br/>角度計算・近側選択・基準ベクトル解決"]
        d2["TimedConditionGate<br/>連続条件"]
        d3["CalibrationLogic"]
    end
    subgraph L1["Types / NekozeFix/Types/"]
        t1["SessionSnapshot / SessionPhase"]
        t2["ReferenceVector"]
        t3["MotionUpdateFrequency"]
    end

    L5 -->|"公開状態を購読"| L4
    L4 -->|"I/O・資源を利用"| L3
    L3 -->|"純ロジックを呼ぶ"| L2
    L2 -->|"値型を共有"| L1
    L3 -.->|"値型を共有"| L1
    L4 -.->|"値型を共有"| L1

    classDef types fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20
    classDef domain fill:#e3f2fd,stroke:#1565c0,color:#0d47a1
    classDef services fill:#fff3e0,stroke:#ef6c00,color:#e65100
    classDef session fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c
    classDef ui fill:#fce4ec,stroke:#ad1457,color:#880e4f

    class t1,t2,t3 types
    class d1,d2,d3 domain
    class sv1,sv2,sv3,sv4,sv5 services
    class s1,s2,s3,s4,s5 session
    class ui1 ui
```

## 3. ディレクトリ構成（層で分割）

機能ではなく**層**で分割する。テストはフラット配置。

```mermaid
mindmap
  root((NekozeFix))
    Types
      PostureTypes.swift
    Domain
      PostureAnalyzer.swift
      TimedConditionGate.swift
      CalibrationLogic.swift
    Services
      CameraSessionManager.swift
      PoseDetector.swift
      MotionService.swift
      AlertPlayer.swift
      DeviceRotationService.swift
    Session
      PostureSessionManager.swift
      FrameThrottle.swift
      MainHopGate.swift
      DimPowerPolicy.swift
      SettingsStore.swift
    UI
      RootView.swift
      MonitorView.swift
      CalibrationView.swift
      CameraPreviewView.swift
      PostureOverlayView.swift
      PermissionView.swift
      SplashView.swift
      DebugConfidenceView.swift
    NekozeFixApp.swift
    Resources
    Assets.xcassets
```

```mermaid
flowchart TD
    root["リポジトリルート"]
    root --> app["NekozeFix/<br/>アプリ本体（層で分割）"]
    root --> tests["NekozeFixTests/<br/>対象ごとにフラット配置"]
    root --> kiro[".kiro/<br/>steering / specs"]
    root --> docs["docs/adr/<br/>設計判断の根拠"]

    app --> types["Types/<br/>共有の値型・列挙"]
    app --> domain["Domain/<br/>純関数のみ"]
    app --> services["Services/<br/>外部I/Oと端末資源"]
    app --> session["Session/<br/>状態所有と結線"]
    app --> ui["UI/<br/>SwiftUI 画面"]
```

## 4. 配置の判断フロー

新しい型・関数をどの層に置くかの目安。

```mermaid
flowchart TD
    q1{"共有の値型か?"} -->|"Yes"| types["Types/PostureTypes.swift<br/>(単一ファイル)"]
    q1 -->|"No"| q2{"判定・計算の純ロジックか?"}
    q2 -->|"Yes"| q3{"I/O が混ざるか?"}
    q3 -->|"No"| domain["Domain/"]
    q3 -->|"Yes"| services["Services/"]
    q2 -->|"No"| q4{"デバイス資源・外部FWの利用か?"}
    q4 -->|"Yes"| services2["Services/<br/>必要ならプロトコルのシームを切って<br/>Types に置く"]
    q4 -->|"No"| q5{"状態遷移・結線・ライフサイクルか?"}
    q5 -->|"Yes"| session["Session/<br/>小さな純粋方針は値型に切り出す"]
    q5 -->|"No"| ui["UI/"]
```
