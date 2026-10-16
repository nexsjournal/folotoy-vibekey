// main/ib_ui_idle.c: IDLE 页:当前模式卡片。
//
// 布局(页面坐标,图标中心 (IB_UI_CX, 104),右侧留给按键提示列):
//   外圈    r=48 的 2 px 灰色细圈 + 极柔和的白色光晕(3 秒周期呼吸),静止不动
//   图标    56 px Material Icons Round 字形:dict = mic、tr = translate、sub = closed_caption
//   模式名  Montserrat 20 @ y=168
//   分页点  3 个,当前模式为白色、更宽的胶囊,其余为灰色圆点 @ y=202
//   引擎名  12 号小字 @ y=240(操作提示由右侧按键提示列承担)
// 切换模式:两个"槽位"(图标 + 模式名)交替使用,旧的向一侧滑出淡出、新的从另一侧滑入
// (250 ms ease-out),位移等于内容区宽度,所以新旧两个模式名任何时刻都不会重叠(超出内容区的部分被裁掉);
// 分页点胶囊同步移动。
// 单色风格:所有模式都用白 / 灰,不区分模式颜色。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define CX            IB_UI_CX            // 内容区中心(右侧留给按键提示列)
#define CY            104
#define ICON_R        48
#define BREATH_MS     3000
#define SLIDE_MS      250
#define SLIDE_PX      IB_UI_CONTENT_W     // 新旧卡片相距一整个内容区宽度,文字不会重叠
#define INTRO_MS      320

typedef struct {
    lv_obj_t *box;
    lv_obj_t *icon;
    lv_obj_t *name;
    ib_ui_mode_t mode;
} slot_t;

static slot_t s_slots[2];
static int s_front;                 // 当前显示的槽位
static int s_slide_dir;             // +1:新卡片从右侧进入;-1:从左侧进入
static ib_ui_mode_t s_mode;
static lv_obj_t *s_glow;
static lv_obj_t *s_dots;
static lv_obj_t *s_engine;

static int32_t s_breath;            // 0..IB_P_ONE
static int32_t s_scale = IB_P_ONE;  // 进入页面时 0.9 → 1.0 的轻微放大
static int32_t s_dot_w[IB_UI_MODE_COUNT];   // 分页点当前宽度(x16 定点)

static const char *const MODE_NAMES[IB_UI_MODE_COUNT] = { "DICTATE", "TRANSLATE", "SUBTITLES" };

static int32_t sc(int32_t v)
{
    return v * s_scale / IB_P_ONE;
}

// ---- 自绘:图标外圈(静止,不随卡片滑动)----
static void glow_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    int32_t c = fx.w / 2;
    // 极柔和的白色光晕随呼吸明暗:用不透明的精确灰画(见 ib_ui_gfx.h 的配色说明),外圈更宽更暗。
    ib_fx_ring(&fx, c, c, sc(ICON_R + 9), 6, ib_gray(0x08 + s_breath * 0x10 / IB_P_ONE), LV_OPA_COVER);
    ib_fx_ring(&fx, c, c, sc(ICON_R + 4), 4, ib_gray(0x10 + s_breath * 0x20 / IB_P_ONE), LV_OPA_COVER);
    // 2 px 灰色细圈。
    ib_fx_ring(&fx, c, c, sc(ICON_R), 2, IB_C(IB_COLOR_RING), LV_OPA_COVER);
}

// ---- 自绘:模式图标(56 px Material Icons 字形,随卡片滑动)----
static void icon_draw(lv_event_t *e)
{
    static const ib_glyph_t GLYPH[IB_UI_MODE_COUNT] = {
        [IB_UI_MODE_DICT] = IB_GLYPH_MIC, [IB_UI_MODE_TR] = IB_GLYPH_TRANSLATE, [IB_UI_MODE_SUB] = IB_GLYPH_CC,
    };
    const slot_t *slot = lv_event_get_user_data(e);
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_fx_text(&fx, fx.w / 2, fx.h / 2, ib_glyph(GLYPH[slot->mode]), &ib_icon_font_56, IB_C(IB_COLOR_TEXT),
               LV_OPA_COVER);
}

// ---- 自绘:分页点 ----
static void dots_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    const int32_t gap = 6, h = 6;
    int32_t total = gap * (IB_UI_MODE_COUNT - 1);
    for (int i = 0; i < IB_UI_MODE_COUNT; i++) total += s_dot_w[i] / 16;
    int32_t x = (fx.w - total) / 2;
    for (int i = 0; i < IB_UI_MODE_COUNT; i++) {
        int32_t w = s_dot_w[i] / 16;
        bool on = (ib_ui_mode_t)i == s_mode;
        ib_fx_rect(&fx, x, (fx.h - h) / 2, w, h, h / 2, on ? IB_C(IB_COLOR_TEXT) : ib_gray(0x48), LV_OPA_COVER);
        x += w + gap;
    }
}

// ---- 槽位与滑动 ----
static void slot_set(slot_t *slot, ib_ui_mode_t mode)
{
    slot->mode = mode;
    lv_label_set_text_static(slot->name, MODE_NAMES[mode]);
    lv_obj_invalidate(slot->icon);
}

static void slot_place(slot_t *slot, int32_t dx, lv_opa_t opa)
{
    lv_obj_set_style_translate_x(slot->box, dx, 0);
    lv_obj_set_style_opa(slot->box, opa, 0);
}

static void slide_cb(lv_anim_t *a, int32_t v)
{
    (void)a;
    // v: 0..IB_P_ONE(已经过 ease-out)。
    slot_t *in = &s_slots[s_front];
    slot_t *out = &s_slots[1 - s_front];
    slot_place(in, s_slide_dir * SLIDE_PX * (IB_P_ONE - v) / IB_P_ONE, ib_opa_scale(255, v));
    slot_place(out, -s_slide_dir * SLIDE_PX * v / IB_P_ONE, ib_opa_scale(255, IB_P_ONE - v));
    lv_obj_invalidate(s_dots);
}

static void refresh_labels(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text(s_engine, ctx->engine);
}

static void snap_to(ib_ui_mode_t mode)
{
    lv_anim_delete(&s_slots[0], NULL);
    s_mode = mode;
    slot_set(&s_slots[s_front], mode);
    slot_place(&s_slots[s_front], 0, LV_OPA_COVER);
    slot_place(&s_slots[1 - s_front], 0, LV_OPA_TRANSP);
    for (int i = 0; i < IB_UI_MODE_COUNT; i++) s_dot_w[i] = ((ib_ui_mode_t)i == mode ? 18 : 6) * 16;
}

static void slide_to(ib_ui_mode_t mode)
{
    // 循环顺序 dict → tr → sub:前进时新卡片从右侧进入,后退时从左侧进入。
    s_slide_dir = mode == (ib_ui_mode_t)((s_mode + 1) % IB_UI_MODE_COUNT) ? 1 : -1;
    s_mode = mode;
    s_front = 1 - s_front;
    slot_set(&s_slots[s_front], mode);

    lv_anim_delete(&s_slots[0], NULL);
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, &s_slots[0]);      // 仅作为动画的唯一标识
    lv_anim_set_custom_exec_cb(&a, slide_cb);
    lv_anim_set_values(&a, 0, IB_P_ONE);
    lv_anim_set_duration(&a, SLIDE_MS);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
    lv_anim_start(&a);
}

// ---- 页面接口 ----
static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_glow = ib_fx_create(root, CX - 80, CY - 80, 160, 160, glow_draw, NULL);
    for (int i = 0; i < 2; i++) {
        slot_t *slot = &s_slots[i];
        slot->box = ib_box_create(root, 0, 0, IB_UI_CONTENT_W, 200);
        slot->icon = ib_fx_create(slot->box, CX - ICON_R, CY - ICON_R, ICON_R * 2, ICON_R * 2, icon_draw, slot);
        slot->name = ib_label_create(slot->box, &lv_font_montserrat_20, IB_COLOR_TEXT, 168, IB_UI_CONTENT_W);
        slot->mode = IB_UI_MODE_DICT;
    }
    s_dots = ib_fx_create(root, CX - 40, 202, 80, 12, dots_draw, NULL);
    s_engine = ib_label_create(root, &lv_font_montserrat_12, IB_COLOR_TEXT_DIM, 240, IB_UI_CONTENT_W - 20);
    snap_to(IB_UI_MODE_DICT);
    return root;
}

static void enter(const ib_ui_ctx_t *ctx)
{
    snap_to(ctx->mode);
    refresh_labels(ctx);
    s_scale = IB_P_ONE * 9 / 10;
}

static void update(const ib_ui_ctx_t *ctx)
{
    if (ctx->mode != s_mode) slide_to(ctx->mode);
    refresh_labels(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    s_breath = ib_ease_in_out_sine(ib_breath(ctx->now_ms, BREATH_MS));
    int32_t intro = ib_ease_out_cubic(ib_progress(ctx->now_ms, ctx->enter_ms, INTRO_MS));
    int32_t scale = IB_P_ONE * 9 / 10 + intro / 10;
    if (scale != s_scale) {
        s_scale = scale;
        lv_obj_invalidate(s_glow);
    }
    // 分页点宽度缓动(每帧靠近 30%)。
    bool dots_moving = false;
    for (int i = 0; i < IB_UI_MODE_COUNT; i++) {
        int32_t target = ((ib_ui_mode_t)i == s_mode ? 18 : 6) * 16;
        int32_t d = target - s_dot_w[i];
        if (d != 0) {
            s_dot_w[i] += (d * 3 / 10) != 0 ? d * 3 / 10 : (d > 0 ? 1 : -1);
            dots_moving = true;
        }
    }
    if (dots_moving) lv_obj_invalidate(s_dots);
    lv_obj_invalidate(s_glow);
}

const ib_ui_page_t ib_ui_page_idle = { create, enter, update, frame };
