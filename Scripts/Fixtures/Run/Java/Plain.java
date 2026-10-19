public class Plain {
    public static void main(String[] args) throws Exception {
        System.out.print(new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8));
        System.err.print("警告だけでも成功");
    }
}
