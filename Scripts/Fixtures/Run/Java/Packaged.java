/* package misleading; class Wrong {} */
package 実例;
public class Packaged {
    String text = "package wrong; class Fake {}";
    String block = """
        package fake; class Nope {}
        """;
    static class Inner { static String text() { return "日本語😀"; } }
    public static void main(String[] args) { System.out.print(Helper.text() + Inner.text()); }
}
class Helper { static String text() { return "helper:"; } }
