use std::ptr;

#[test]
fn links_and_initializes_freetype() {
    let mut library = ptr::null_mut();

    let error = unsafe { freetype_sys::FT_Init_FreeType(&mut library) };
    assert_eq!(error, 0, "FT_Init_FreeType failed with error {error}");
    assert!(
        !library.is_null(),
        "FT_Init_FreeType returned a null library"
    );

    let error = unsafe { freetype_sys::FT_Done_FreeType(library) };
    assert_eq!(error, 0, "FT_Done_FreeType failed with error {error}");
}
