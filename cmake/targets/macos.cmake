# macOS specific target definitions

target_link_options(sunshine PRIVATE LINKER:-sectcreate,__TEXT,__info_plist,${APPLE_PLIST_FILE})

target_link_options(sunshine PRIVATE -Wl,-U,_CGPreflightScreenCaptureAccess -Wl,-U,_CGRequestScreenCaptureAccess)

target_link_libraries(sunshine ${MACOS_REQUIRED_FRAMEWORKS})

if(SUNSHINE_ENABLE_TRAY AND COCOA)
    target_link_libraries(sunshine ${COCOA})
endif()
