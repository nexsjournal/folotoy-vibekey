import Foundation

/// 内置推荐词汇。只做“追加合并”，不会删除用户自己写的词。
/// `#` 开头是分组标题，解析词汇表时会忽略；别名只放“常见误识别 / 缩写”，不放同义词，
/// 避免把“日活”强行改成 DAU 这类翻译行为。
nonisolated enum VocabularyPresets {
    /// 以后更新推荐词时递增，AppSettings 会做一次合并迁移。
    static let version = 1

    static let text = """
    # AI 模型 / 产品
    DeepSeek = DIPSEEK, deep seek, 迪普希克, 深度求索
    ChatGPT = chat gpt, chatGPT
    GPT-4o = GPT4o, GPT 4o
    GPT-5 = GPT5, GPT 5
    Claude
    Claude Code
    Gemini
    Qwen
    通义千问
    Kimi
    月之暗面
    Doubao
    豆包
    GLM
    ChatGLM
    LLaMA = llama
    Mistral
    Grok
    Midjourney = mid journey, MJ
    Stable Diffusion = stable diffusion, SD
    ComfyUI = comfy UI
    Flux
    Sora
    Runway
    Pika
    Suno
    ElevenLabs = eleven labs
    Whisper
    WhisperKit = whisper kit
    Ollama = o llama
    LangChain = lang chain
    LlamaIndex = llama index
    Hugging Face = huggingface
    NVIDIA
    英伟达
    OpenAI
    Anthropic
    Microsoft
    Google
    Meta

    # AI 基础
    RAG = R A G
    检索增强生成
    MCP = Model Context Protocol
    Agent
    智能体
    Multi-Agent = multi agent
    多智能体
    Prompt
    提示词
    Fine-tuning = fine tuning
    微调
    LoRA
    RLHF
    Embedding
    向量
    Vector Database = vector DB
    向量数据库
    Token
    词元
    Context Window = context length
    上下文窗口
    Hallucination
    幻觉
    Inference
    推理
    Multimodal = multi modal
    多模态
    Diffusion
    扩散模型
    Transformer
    Attention
    注意力机制
    Benchmark
    基准测试
    AGI
    AIGC
    LLM
    大语言模型
    GPU
    CUDA
    TPU
    API
    SDK
    GitHub = git hub
    Open Source
    开源
    Serverless
    Cloud Native
    云原生

    # 互联网产品 / 产品经理
    PRD
    需求文档
    用户画像
    用户旅程
    用户增长
    留存率
    转化率
    DAU
    日活
    MAU
    月活
    北极星指标
    MVP
    最小可行产品
    敏捷开发
    灰度发布
    A/B 测试 = AB 测试
    埋点
    漏斗分析
    竞品分析
    商业模式
    订阅制
    会员体系
    增长黑客
    冷启动
    私域流量
    公域流量
    裂变
    转化漏斗
    UX
    UI
    用户体验
    用户界面
    交互设计
    信息架构
    可用性测试
    设计系统
    组件库
    原型图
    线框图
    高保真

    # 设计
    Figma = fig ma
    Sketch
    Framer
    Adobe XD = XD
    Photoshop
    Illustrator
    Blender
    Cinema 4D = C4D
    After Effects = AE
    Premiere Pro
    DaVinci Resolve = 达芬奇
    视觉设计
    品牌设计
    平面设计
    动效设计
    排版
    字重
    行高
    栅格
    留白
    对比度
    色彩系统
    无障碍设计
    Accessibility
    设计规范
    设计稿
    切图
    矢量图
    位图
    分辨率
    DPI
    玻璃拟态 = Glassmorphism
    新拟态 = Neumorphism
    极简主义
    包豪斯
    瑞士国际主义
    孟菲斯
    赛博朋克
    像素风
    蒸汽波

    # 电影
    分镜
    Storyboard
    运镜
    景别
    特写
    长镜头
    蒙太奇
    叙事结构
    三幕式
    英雄之旅
    票房
    院线
    流媒体
    制片人
    导演
    编剧
    摄影指导
    DP
    剪辑
    调色
    音效
    配乐
    混音
    杜比全景声
    IMAX = I MAX
    奥斯卡
    Oscar
    戛纳
    柏林电影节
    威尼斯电影节
    圣丹斯

    # 前端开发
    JavaScript = JS, java script
    TypeScript = TS, type script
    React
    Next.js = NextJS, next js
    Vue
    Nuxt
    Svelte
    Angular
    Tailwind CSS = Tailwind
    HTML
    CSS
    Webpack
    Vite
    pnpm
    npm
    Node.js = NodeJS, node js
    Bun
    Electron
    Tauri
    WebAssembly = WASM
    GraphQL = graph QL
    RESTful API
    REST
    WebSocket = web socket
    Service Worker
    PWA
    SSR
    服务端渲染
    CSR
    客户端渲染
    Hydration
    水合
    Virtual DOM
    虚拟 DOM
    React Query
    Storybook
    Playwright
    Cypress
    Lighthouse
    Core Web Vitals
    响应式布局
    跨端
    小程序
    HarmonyOS
    鸿蒙

    # 后端开发
    Java
    Spring Boot
    Golang
    Go
    Rust
    Python
    Django
    FastAPI
    Flask
    MySQL
    PostgreSQL = Postgres, postgre SQL
    Redis
    MongoDB
    Kafka
    RabbitMQ
    Elasticsearch
    ClickHouse
    Docker
    Kubernetes = K8s, k 8 s
    Helm
    Terraform
    Nginx = engine x
    CI/CD = CI CD
    DevOps
    SRE
    微服务
    单体架构
    分布式系统
    负载均衡
    限流
    熔断
    降级
    消息队列
    缓存
    数据库索引
    事务
    幂等
    一致性哈希
    CAP 定理
    gRPC = g RPC
    Protobuf = proto buf
    OAuth = O auth
    JWT = J W T
    SSO = S S O
    网关
    AWS
    Azure
    Google Cloud
    GCP
    阿里云
    腾讯云
    火山引擎
    Cloudflare
    Vercel
    Supabase

    # 历史
    先秦
    春秋战国
    秦始皇
    汉武帝
    唐朝
    宋朝
    明朝
    清朝
    辛亥革命
    五四运动
    抗日战争
    改革开放
    文艺复兴
    工业革命
    法国大革命
    第一次世界大战
    一战
    第二次世界大战
    二战
    冷战
    古埃及
    古希腊
    古罗马
    玛雅文明
    丝绸之路
    大航海时代
    启蒙运动
    明治维新

    # 地理 / 常识
    北京
    上海
    广州
    深圳
    杭州
    成都
    重庆
    西安
    南京
    苏州
    武汉
    长沙
    香港
    澳门
    台湾
    东京
    大阪
    首尔
    新加坡
    曼谷
    伦敦
    巴黎
    柏林
    纽约
    旧金山
    洛杉矶
    西雅图
    波士顿
    硅谷
    太平洋
    大西洋
    印度洋
    北冰洋
    长江
    黄河
    珠穆朗玛峰
    Everest
    珠峰
    撒哈拉沙漠
    亚马逊雨林
    赤道
    经纬度
    时区
    海拔
    气候带
    季风
    板块运动
    地震带
    火山
    台风
    厄尔尼诺
    碳中和
    温室效应
    生物多样性
    """

    static let recommended: [String] = text.split(whereSeparator: \.isNewline).map(String.init)

    /// 追加合并：保留用户已有顺序和写法，只补缺失的正式写法。
    static func merged(into existing: String) -> String {
        var lines = existing.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set(lines.map(key))
        for line in recommended {
            if line.hasPrefix("#") {
                if !lines.contains(line) { lines.append(line) }
                continue
            }
            let term = key(line)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 去重只看等号左边的正式写法；`#` 分组标题不参与。
    private static func key(_ line: String) -> String {
        let value = line.hasPrefix("#") ? "" : line
        let term = value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        return term.lowercased().filter { !$0.isWhitespace }
    }
}
