idf_component_register(
    SRCS "pet_main.c" "pet_model.c" "pet_protocol.c" "pet_store.c" "pet_game.c" "pet_sound.c" "pet_preferences.c"
         "pet_ble.c" "pet_stream.c" "pet_assets.c" "pet_font_16.c" "pet_font_20.c"
    INCLUDE_DIRS "."
    REQUIRES bt bsp json nvs_flash esp_timer esp_app_format esp_driver_usb_serial_jtag
)
