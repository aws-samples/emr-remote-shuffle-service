import org.apache.spark.{SparkConf,SparkContext}
import org.apache.spark.sql.SparkSession
import org.apache.spark.sql.functions.{current_timestamp, unix_timestamp}

object ShuffleTtest {
  def main(args: Array[String]): Unit = {

    val spark = SparkSession
      .builder()
      .appName("ShuffleTest")
      .getOrCreate()
    
    // #TEST 1# - huge shuffle
    val start1 = unix_timestamp(current_timestamp())
    val result = spark.sparkContext.parallelize(1 to 8000, 8000)
        .flatMap( _ => (1 to 45000000).iterator.map(num => num))
        .repartition(8000)
        .count
    printf("Result: %s", result)
    val diff = unix_timestamp(current_timestamp()) - start1
    printf("Shuffle 45000000 took %s seconds", diff)

    // #TEST 2# - smallest shuffle case
    val start2 = unix_timestamp(current_timestamp())
    val result2 = spark.sparkContext.parallelize(1 to 8000, 8000)
        .flatMap( _ => (1 to 15000000).iterator.map(num => num))
        .repartition(8000)
        .count
    printf("Result: %s", result2)
    val diff2 = unix_timestamp(current_timestamp()) - start2
        printf("Shuffle 15000000 took %s seconds", diff2)

    // #TEST 3# - medium size shuffle
    val start3 = unix_timestamp(current_timestamp())
    val result3 = spark.sparkContext.parallelize(1 to 8000, 8000)
        .flatMap( _ => (1 to 30000000).iterator.map(num => num))
        .repartition(8000)
        .count
    printf("Result: %s", result3)
    val diff3 = unix_timestamp(current_timestamp()) - start3
    printf("Shuffle 300 took %s seconds", diff3)

    spark.stop()
  }
}
