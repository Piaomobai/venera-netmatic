#include "my_application.h"

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (g_strcmp0(argv[i], "--headless") == 0) {
      const char* value = g_getenv("FLUTTER_ENGINE_SWITCHES");
      const int count = value ? static_cast<int>(g_ascii_strtoll(value, nullptr, 10)) : 0;
      if (count >= 0 && count < 50) {
        g_autofree gchar* next_count = g_strdup_printf("%d", count + 1);
        g_autofree gchar* key = g_strdup_printf("FLUTTER_ENGINE_SWITCH_%d", count + 1);
        g_setenv("FLUTTER_ENGINE_SWITCHES", next_count, TRUE);
        g_setenv(key, "disable-vm-service", TRUE);
      }
      break;
    }
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
