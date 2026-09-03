idf_component_register(
    SRCS "recovery_boot_hook.c"
    PRIV_REQUIRES bootloader_support spi_flash
    PRIV_INCLUDE_DIRS "$ENV{IDF_PATH}/components/bootloader_support/private_include"
                       "$ENV{IDF_PATH}/components/bootloader_support/bootloader_flash/include"
)
