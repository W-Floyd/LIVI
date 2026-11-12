// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use livi_video_player::{CameraPlayer, Player, UrlPlayer};

use std::sync::OnceLock;

use crate::building::{Builder, Building};
use crate::{CameraOrder, VideoCodec};

pub type Plane = Building<Player>;
pub type Url = UrlPlayer;
pub type Camera = CameraPlayer;

pub fn create_plane(id: u32, codec: VideoCodec, codec_data: &[u8]) -> Option<Plane> {
    static BUILDER: OnceLock<Builder> = OnceLock::new();
    let codec_data = codec_data.to_vec();
    Some(
        BUILDER
            .get_or_init(Builder::new)
            .build(id, move || Player::new(codec, 0, &codec_data)),
    )
}

pub fn open_camera(_id: u32, order: &CameraOrder) -> Option<Camera> {
    let camera = CameraPlayer::new(order, 0, livi_video_player::to_stderr())?;
    camera.start();
    Some(camera)
}

pub fn play_url(_id: u32, url: &str, audio_device: &str) -> Option<Url> {
    UrlPlayer::new(url, audio_device, 0, livi_video_player::to_stderr())
}
