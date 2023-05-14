#include "uniqueID.h"
#include "utils.h"
#include <algorithm>
#include <fstream>
#include <unordered_map>

using namespace std;

unordered_multimap<string, int64_t> user_notification_memcached;
typedef unordered_multimap<string, int64_t>::iterator umit;

#define USER_NUM 30
#define userMention_API_RATIO 100
#define MAX_USER_TAG_PER_REQUEST 3

void userMention(int64_t postID, vector<string> usernames, char **_keys,
                 size_t *_key_sizes) {
  // copied from deathbench
  char **keys = _keys;
  size_t *key_sizes = _key_sizes;
    // keys = new char *[usernames.size()];
    // key_sizes = new size_t[usernames.size()];
  int idx = 0;
  for (auto &username : usernames) {
    std::string key_str = username + ":user_id";
    // keys[idx] = new char[key_str.length() + 1];
    strcpy(keys[idx], key_str.c_str());
    key_sizes[idx] = key_str.length();
    idx++;
    // auto make_pair(username, postID);
    // add to user_notification_memcached
    // user_notification_memcached.insert();
  }
}

void getMentionNotfications(string username, vector<int64_t> &posts,
                            int post_num) {
  pair<umit, umit> it = user_notification_memcached.equal_range(username);
  umit it1 = it.first;
  pair<string, int64_t> tmp;
  int num = 0;

  // looping over all values associated with key
  while (it1 != it.second && num < post_num) {
    tmp = *it1;
    posts.push_back(tmp.second);
    it1++;
    num++;
  }
}

int main(int argc, char *argv[]) {

  if (argc < 2) {
    printf("You must provide the number of reqs\n");
    exit(0);
  }

  srand(1);
  int num_reqs = 0;
  int reqs = 0;

  num_reqs = atoi(argv[1]);
  vector<string> predfined_usernames;
  for (int i = 0; i < USER_NUM; i++) {
    predfined_usernames.push_back(gen_random_string(20));
  }
  user_notification_memcached.rehash(100000);
  // while (reqs < num_reqs) {

  //   if ((rand() % 100) < userMention_API_RATIO || reqs == 0) {
  //     // new userMention
  //     cout << "new userMention event" << endl;
  //     int64_t postID = UploadUniqueId(reqs);
  //     cout << "post id: " << postID << endl;
  //     int username_num = (rand() % MAX_USER_TAG_PER_REQUEST) + 1;
  //     cout << "number of usernames " << username_num << endl;
  //     vector<string> usernames;
  //     for (int i = 0; i < username_num; i++) {
  //       usernames.push_back(predfined_usernames[(rand() % USER_NUM)]);
  //       cout << "username " << i << ":" << usernames[i] << endl;
  //     }
  //     char **keys = new char *[usernames.size()];
  //     int idx = 0;
  //     size_t *key_sizes = new size_t[usernames.size()];
  //     for (auto &username : usernames) {
  //       std::string key_str = username + ":user_id";
  //       keys[idx] = new char[key_str.length() + 1];
  //       idx++;
  //     }
  //     userMention(postID, usernames, keys, key_sizes);
  //     cout << endl;
  //   } else {
  //     cout << "getMentionNotfications event" << endl;
  //     string username = predfined_usernames[(rand() % USER_NUM) + 1];
  //     cout << "user name: " << username << endl;

  //     vector<int64_t> posts;
  //     getMentionNotfications(username, posts, 5);
  //     cout << "number of posts: " << posts.size() << endl;
  //     for (int i = 0; i < posts.size(); ++i)
  //       cout << "post " << i << " : " << posts[i] << endl;

  //     cout << endl;
  //   }

  //   reqs++;
  // }
// #pragma omp parallel for
  for (size_t i = 0; i < num_reqs; i++)

  {
    // new userMention
    cout << "new userMention event" << endl;
    int64_t postID = UploadUniqueId(reqs);
    cout << "post id: " << postID << endl;
    int username_num = (rand() % MAX_USER_TAG_PER_REQUEST) + 1;
    cout << "number of usernames " << username_num << endl;
    vector<string> usernames;
    for (int i = 0; i < username_num; i++) {
      usernames.push_back(predfined_usernames[(rand() % USER_NUM)]);
      cout << "username " << i << ":" << usernames[i] << endl;
    }
    char **keys = new char *[usernames.size()];
    int idx = 0;
    size_t *key_sizes = new size_t[usernames.size()];
    for (auto &username : usernames) {
      std::string key_str = username + ":user_id";
      keys[idx] = new char[key_str.length() + 1];
      idx++;
    }
    userMention(postID, usernames, keys, key_sizes);
    cout << endl;
  }
  return 0;
}