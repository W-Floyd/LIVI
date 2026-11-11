//! livi-ui's file browser (files_ui.rs) for the pages that import a file: folders under home and
//! the mounted volumes, only the files the page takes; and its icon import (icon_ui.rs).

use std::io::Cursor;
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat};
use livi_core_proto::icon::SIZES;
use livi_ui_model::i18n::Strings;
use livi_ui_model::settings::custom::files::{Entry, Wanted, entry_rows, listing};
use livi_ui_model::settings::view::Row;

const VOLUMES: [&str; 4] = ["/Volumes", "/media", "/run/media", "/mnt"];

pub struct Browser {
    wanted: Wanted,
    roots: Vec<PathBuf>,
    dir: Option<PathBuf>,
    entries: Vec<(Entry, PathBuf)>,
}

pub enum Picked {
    Entered,
    File(Wanted, PathBuf),
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map_or_else(|| path.display().to_string(), |n| n.to_string_lossy().into_owned())
}

fn read_dir(dir: &Path, wanted: Wanted) -> Vec<(Entry, PathBuf)> {
    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let raw: Vec<(Entry, PathBuf)> = read
        .flatten()
        .map(|e| {
            let path = e.path();
            (Entry { name: e.file_name().to_string_lossy().into_owned(), dir: path.is_dir() }, path)
        })
        .collect();
    listing(raw.iter().map(|(e, _)| e.clone()).collect(), wanted)
        .into_iter()
        .filter_map(|e| raw.iter().find(|(r, _)| *r == e).cloned())
        .collect()
}

impl Browser {
    /// `roots` empty: home and the mounted volumes.
    pub fn open(wanted: Wanted, roots: &[PathBuf]) -> Self {
        let roots: Vec<PathBuf> = if roots.is_empty() {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .into_iter()
                .chain(VOLUMES.iter().map(PathBuf::from))
                .filter(|p| p.is_dir())
                .collect()
        } else {
            roots.to_vec()
        };
        let mut b = Self { wanted, roots, dir: None, entries: Vec::new() };
        b.show(None);
        b
    }

    fn show(&mut self, dir: Option<PathBuf>) {
        self.entries = match &dir {
            Some(d) => read_dir(d, self.wanted),
            None => self
                .roots
                .iter()
                .map(|p| (Entry { name: name_of(p), dir: true }, p.clone()))
                .collect(),
        };
        self.dir = dir;
    }

    pub fn pick(&mut self, i: usize) -> Option<Picked> {
        let (entry, path) = self.entries.get(i).cloned()?;
        if entry.dir {
            self.show(Some(path));
            Some(Picked::Entered)
        } else {
            Some(Picked::File(self.wanted, path))
        }
    }

    /// Up a folder; false at the roots' list, which closes the browser.
    pub fn up(&mut self) -> bool {
        let Some(dir) = self.dir.clone() else {
            return false;
        };
        let parent = (!self.roots.contains(&dir)).then(|| dir.parent().map(Path::to_path_buf)).flatten();
        self.show(parent);
        true
    }

    pub fn title(&self, t: &Strings) -> String {
        match &self.dir {
            Some(d) => name_of(d),
            None => self.wanted.title(t),
        }
    }

    pub fn rows(&self, t: &Strings) -> Vec<Row> {
        let entries: Vec<Entry> = self.entries.iter().map(|(e, _)| e.clone()).collect();
        entry_rows(&entries, self.wanted, t)
    }
}

fn png(img: &DynamicImage, size: u32) -> Result<String, String> {
    let mut out = Vec::new();
    img.resize_to_fill(size, size, FilterType::Lanczos3)
        .write_to(&mut Cursor::new(&mut out), ImageFormat::Png)
        .map_err(|e| e.to_string())?;
    Ok(STANDARD.encode(out))
}

/// A picture as the phone icon's three sizes, centre-cropped square, base64 PNGs.
pub fn import_icon(path: &Path) -> Result<[String; 3], String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let img = image::load_from_memory(&bytes).map_err(|e| e.to_string())?;
    let largest = SIZES.iter().map(|(_, s)| *s).max().unwrap_or(256);
    // Lanczos over a camera-sized picture is slow on the unit: down to twice the largest first.
    let base = if img.width().min(img.height()) > largest * 2 {
        img.resize_to_fill(largest * 2, largest * 2, FilterType::Triangle)
    } else {
        img
    };
    Ok([png(&base, SIZES[0].1)?, png(&base, SIZES[1].1)?, png(&base, SIZES[2].1)?])
}
