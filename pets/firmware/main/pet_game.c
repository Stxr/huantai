#include "pet_game.h"
pet_game_action_t pet_game_press(pet_game_t *g, unsigned button, unsigned event, bool adopted, unsigned sessions)
{
    if (!g || button > 2 || event < 1 || event > 3) return PET_GAME_NONE;
    if (button == 2 && event == 3) { g->settings = !g->settings; g->confirm = false; return PET_GAME_NONE; }
    if (g->pending) return PET_GAME_NONE;
    if (g->settings) {
        if (event == 1 && button < 2) g->settings_page = (g->settings_page + (button ? 1 : PET_SETTINGS_COUNT-1)) % PET_SETTINGS_COUNT;
        if (event == 1 && button == 2 && g->settings_page==2) return PET_GAME_BRIGHTNESS;
        if (event == 1 && button == 2 && g->settings_page==3) return PET_GAME_MIC_THRESHOLD;
        return PET_GAME_NONE;
    }
    if (!adopted) {
        if (event == 1 && button < 2) { g->choice = (g->choice + (button ? 1 : 5)) % 6; g->confirm = false; }
        else if (button == 2 && event == 2) g->confirm = false;
        else if (button == 2 && event == 1) {
            if (g->confirm) { g->pending = true; return PET_GAME_ADOPT; }
            g->confirm = true;
        }
        return PET_GAME_NONE;
    }
    if (button == 2 && event == 2) { g->page = (g->page + 1) % 3; return PET_GAME_NONE; }
    if (g->page == 1 && sessions) {
        if (button < 2 && event == 1) g->selected = (g->selected + (button ? 1 : sessions - 1)) % sessions;
        else if (button == 2 && event == 1) { g->pending = true; return PET_GAME_OPEN; }
    }
    return PET_GAME_NONE;
}
