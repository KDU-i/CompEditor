import java.time.Month;
import java.time.format.TextStyle;
import java.util.Locale;
public class LocaleOutput {
    public static void main(String[] args) {
        Locale locale = Locale.getDefault();
        System.out.print(locale.toLanguageTag() + "|" + Month.OCTOBER.getDisplayName(TextStyle.FULL, locale));
    }
}
