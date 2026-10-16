// main/ib_icons.c: 图标 id 映射实现(见 ib_icons.h)。
#include "ib_icons.h"

#include <stddef.h>
#include <string.h>

static const char *const IDS[IB_ICON_COUNT] = {
    [IB_ICON_NONE] = "",
#define IB_ICON_DEF(name, id, glyph, codepoint) [IB_ICON_##name] = id,
#include "icons/ib_icon_list.h"
#undef IB_ICON_DEF
};

ib_icon_t ib_icon_from_id(const char *id)
{
    if (id == NULL || id[0] == '\0') return IB_ICON_NONE;
    for (int i = 1; i < IB_ICON_COUNT; i++) {
        if (strcmp(id, IDS[i]) == 0) return (ib_icon_t)i;
    }
    return IB_ICON_NONE;
}

const char *ib_icon_id(ib_icon_t icon)
{
    return (unsigned)icon < IB_ICON_COUNT ? IDS[icon] : "?";
}
