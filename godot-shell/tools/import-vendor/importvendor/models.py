"""What to import per car: where its files sit in the OTA, which apps make up the stock look,
and the screens to resolve. Values that the stock app sets from code at run time (which views
show, which range-road frame, the numbers) are a hand-picked representative state here."""

SYSTEM = "enc_system/enc_system.ext4/system.ext4"

EV6 = {
    "name": "Kia EV6 (stock)",
    "about": "Imported from the EV6's stock head-unit firmware by tools/import-vendor. "
             "Vendor assets: build locally, never redistribute.",
    "ref": "ref/kia/ev6/2024",
    "secrets_glob": "2022_2024-usa-ev6_*",
    "system": SYSTEM,
    "density": 1.5,
    "panel": [1920, 720],
    "apps": {
        "HKMC_TAppEV3": "app",
        "Launcher_WP3": "app",
        "RightScreenHome": "app",
        "HKMC_Climate": "app",
        "HKMC_VehicleSetting": "app",
        "HKMC_HomeSetting_WP": "app",
        "ThemeSettings": "app",
        "Mobis_SystemPopup": "app",
        "SystemUI": "priv-app",
    },
    "framework": ["framework-res", "hkmc-res"],
    "fonts": {"regular": "Mobis-Regular.ttf", "bold": "Mobis-Bold.ttf"},
    # Apps whose every drawable goes into the pack; the others contribute tokens only.
    "image_apps": ["HKMC_TAppEV3", "Launcher_WP3", "SystemUI"],
    "screens": {
        "ev_main": {
            "app": "HKMC_TAppEV3",
            "layout": "layout_main",
            # The app's window, under the 60 dp status bar.
            "window_dp": [0, 60, 1280, 420],
            "status_bar": {"image": "SystemUI/co_bg_status", "height_dp": 60},
            "state": {
                "visible": ["evmain_view", "mainview_nearbystation_01", "mainview_nearby_stattion_arrow"],
                "hidden": ["mainview_nearbystation__son", "mainview_energyinformation_battery_charging_image",
                           "mainview_solar_roof_title", "mainview_solar_roof_image",
                           "mainview_nextDeparture_value_son"],
                "background": {"mainview_climate_progress_status": "@drawable/ev_etc_main_case1_01",
                               "mainview_energyinformation_battery_image": "@drawable/ev_etc_battery_10"},
                "text": {
                    "mainview_text_climateon_range_value": "243",
                    "mainview_text_climateoff_range_value": "253",
                    "mainview_text_nearyby_station_range_value": "740",
                    "mainview_text_nearyby_station_range_unit": "m",
                    "mainview_text_nearyby_station_location": "Digital Energy Solutions",
                    "mainview_text_battery_percentage_value": "50",
                },
            },
        },
    },
}

MODELS = {"ev6": EV6}
